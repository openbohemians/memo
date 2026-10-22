require "arcana-core"
require "http/client"
require "./service"
require "./namespaces"
require "./bus_log"

module Memo
  # Serves ArcanaService's API on an Arcana::Client.
  #
  # Requests run concurrently, up to max_concurrency at a time. The client
  # calls on_message from its WebSocket read loop, so handling a request
  # there would hold up every other request, and the replies that memo's own
  # bus calls (the bus/* embedding formats) are waiting for.
  #
  # Up to max_waiting more requests wait for a turn. Beyond that, memo
  # answers "busy" at once instead of queueing without limit; the read loop
  # can't simply block for backpressure, since memo's own bus calls need it.
  class ArcanaListener
    include BusLog

    ADDRESS = "memo:rag"

    def initialize(@client : Arcana::Client, @namespaces : Namespaces,
                   max_concurrency : Int32 = 32, @max_waiting : Int32 = max_concurrency * 8)
      @handler = ArcanaService.new(@namespaces)
      @slots = Channel(Nil).new(max_concurrency)
      @waiting = 0
    end

    # Is a memo-arcana already serving ADDRESS on the bus at host:port?
    # Another one mustn't join: it would share the address's mailbox, and
    # when either connection closed, the bus would drop the address for
    # both. The bus keeps a joined service's listing across its own
    # restarts, so a listed address is asked for help, and only a reply
    # counts. Two instances starting at the same moment can both pass.
    def self.already_running?(host : String, port : Int32, timeout : Time::Span = 3.seconds) : Bool
      listed?(host, port) && answers_help?(host, port, timeout)
    end

    # Unless the bus says ADDRESS isn't listed. A bus that can't be reached
    # counts as not listed, so joining it fails with the real error.
    private def self.listed?(host : String, port : Int32) : Bool
      http = HTTP::Client.new(host, port)
      http.connect_timeout = 2.seconds
      http.read_timeout = 2.seconds
      !http.get("/directory/#{ADDRESS}").status.not_found?
    rescue IO::Error | Socket::Error
      false
    ensure
      http.try(&.close)
    end

    private def self.answers_help?(host : String, port : Int32, timeout : Time::Span) : Bool
      probe = Arcana::Client.new(url: "ws://#{host}:#{port}/bus",
        address: "memo-arcana-check-#{Random::Secure.hex(4)}", listed: false)
      spawn do
        probe.connect
      rescue
        # not connected, so no reply: the check passes
      end
      waited = Time.instant
      until probe.connected? || Time.instant - waited > timeout
        sleep 10.milliseconds
      end
      return false unless probe.connected?

      help = Arcana::Envelope.new(from: probe.address, to: ADDRESS, subject: "help",
        payload: JSON.parse(%({"_intent":"help"})))
      probe.request(help, timeout: timeout).try(&.from) == ADDRESS
    ensure
      probe.try(&.close)
    end

    # Answer requests arriving on the client
    def listen : Nil
      @client.on_message do |envelope|
        next if ignored_reply?(envelope)
        if @waiting >= @max_waiting
          reject_busy(envelope)
          next
        end

        @waiting += 1
        spawn do
          @slots.send(nil)
          @waiting -= 1
          begin
            handle(envelope)
          ensure
            @slots.receive
          end
        end
      end
    end

    # A reply (result, need, help, error) isn't a request: e.g. an embedding
    # reply that arrived after memo stopped waiting for it. Answering it with
    # an error could start an error ping-pong with the sender.
    private def ignored_reply?(envelope : Arcana::Envelope) : Bool
      payload = envelope.payload
      status = payload.as_h? ? Arcana::Protocol.status(payload) : nil
      return false unless status && status != "request"
      log "#{DIM}ignored    #{envelope.from.ljust(12)} unexpected #{status} reply#{RESET}"
      true
    end

    private def reject_busy(envelope : Arcana::Envelope) : Nil
      log "#{YELLOW}busy#{RESET}       #{DIM}#{envelope.from.ljust(12)}#{RESET} rejected, #{@waiting} waiting"
      payload = JSON::Any.new({
        "_proto"  => JSON::Any.new("arcana/1"),
        "_status" => JSON::Any.new("error"),
        "code"    => JSON::Any.new("busy"),
        "message" => JSON::Any.new("memo is busy (#{@waiting} requests waiting); retry shortly"),
      } of String => JSON::Any)
      @client.send(envelope.reply(from: ADDRESS, payload: payload))
    rescue
      # client may be closed
    end

    # Every `interval`, save the indexes of open namespaces that are due.
    # Memo saves on its own after writes; this catches changes that have
    # gone unsaved too long without further writes.
    def save_periodically(interval : Time::Span) : Nil
      spawn do
        loop do
          sleep interval
          @namespaces.open_services.each do |ns, svc|
            svc.save_index_if_due
          rescue ex
            log "#{RED}error#{RESET}      saving #{ns} index: #{redact_db_url(ex.message.to_s)}"
          end
        end
      end
    end

    # Answer one request envelope.
    def handle(envelope : Arcana::Envelope) : Nil
      payload = envelope.payload

      begin
        data = if payload.as_h? && payload["_proto"]?
                 payload["data"]? || JSON::Any.new(nil)
               else
                 payload
               end

        action = data["action"]?.try(&.as_s?) || "?"
        from = envelope.from
        t_start = Time.instant

        # Help intent
        if payload.as_h? && payload["_intent"]?.try(&.as_s?) == "help"
          help_payload = JSON.parse(%({"_proto":"arcana/1","_status":"help","guide":#{ArcanaService::GUIDE.to_json},"schema":#{ArcanaService::SCHEMA.to_json}}))
          @client.send(envelope.reply(from: ADDRESS, payload: help_payload))
          return
        end

        result = @handler.handle(data)
        elapsed_ms = (Time.instant - t_start).total_milliseconds.round(1)

        status_color = elapsed_ms > 500 ? YELLOW : GREEN
        summary = summarize(data)
        extra = ""
        if action == "search"
          if t = result["timings"]?
            cache = t["cache_hit"]?.try(&.as_bool?) ? "#{CYAN}cache#{RESET}" : ""
            n = result["results"]?.try(&.as_a?.try(&.size)) || 0
            extra = " #{DIM}→#{RESET} #{n} hit#{n == 1 ? "" : "s"} #{cache}"
          end
        elsif action == "stats" && result["embeddings"]?
          extra = " #{DIM}→#{RESET} #{result["embeddings"]} emb / #{result["chunks"]} chunks"
        elsif (action == "index" || action == "index_batch") && result["chunks"]?
          extra = " #{DIM}→#{RESET} #{result["chunks"]} chunks"
        end
        log "#{status_color}#{action.ljust(11)}#{RESET} #{DIM}#{from.ljust(12)}#{RESET} #{summary}#{extra} #{DIM}(#{elapsed_ms}ms)#{RESET}"

        result_payload = JSON::Any.new({
          "_proto"  => JSON::Any.new("arcana/1"),
          "_status" => JSON::Any.new("result"),
          "data"    => result,
        } of String => JSON::Any)

        @client.send(envelope.reply(from: ADDRESS, payload: result_payload))
      rescue ex
        # Errors can quote a database URL
        message = redact_db_url(ex.message || "Unknown error")
        error_payload = JSON::Any.new({
          "_proto"  => JSON::Any.new("arcana/1"),
          "_status" => JSON::Any.new("error"),
          "message" => JSON::Any.new(message),
        } of String => JSON::Any)
        begin
          @client.send(envelope.reply(from: ADDRESS, payload: error_payload))
        rescue
          # client may be closed
        end
        log "#{RED}error#{RESET}      #{message}"
      end
    end
  end
end
