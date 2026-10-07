require "arcana-core"
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
            log "#{RED}error#{RESET}      saving #{ns} index: #{ex.message}"
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
        error_payload = JSON::Any.new({
          "_proto"  => JSON::Any.new("arcana/1"),
          "_status" => JSON::Any.new("error"),
          "message" => JSON::Any.new(ex.message || "Unknown error"),
        } of String => JSON::Any)
        begin
          @client.send(envelope.reply(from: ADDRESS, payload: error_payload))
        rescue
          # client may be closed
        end
        log "#{RED}error#{RESET}      #{ex.message}"
      end
    end
  end
end
