require "../src/arcana/service"
require "../src/memo/pg"
require "arcana-core"

# Memo Arcana Bus Service
#
# Connects to an Arcana server via WebSocket and exposes Memo's
# core API as a multi-namespace bus service. Each namespace (ns)
# is an isolated embedding space with its own DB and USearch index.
#
# The same WebSocket connection is shared with Memo::Providers::Bus
# so namespaces using the bus/openai or bus/voyage formats can
# route embedding requests through the bus.
#
# Environment variables:
#   ARCANA_HOST           — Arcana server host (default: 127.0.0.1)
#   ARCANA_PORT           — Arcana server port (default: 19118)
#   MEMO_NAMESPACES       — Path to namespaces config (default: /etc/memo/namespaces.yaml)
#   MEMO_MAX_CONCURRENCY  — Requests handled at once (default: 32)
#   MEMO_SAVE_INTERVAL    — Seconds between saves of changed indexes (default: 60)

# ANSI color helpers
DIM    = "\e[2m"
BOLD   = "\e[1m"
RESET  = "\e[0m"
GREEN  = "\e[32m"
YELLOW = "\e[33m"
RED    = "\e[31m"
CYAN   = "\e[36m"
GRAY   = "\e[90m"

def log(msg : String)
  STDERR.puts "#{GRAY}#{Time.local.to_s("%H:%M:%S")}#{RESET} #{msg}"
end

def truncate(s : String, max : Int32 = 50) : String
  s.size > max ? "#{s[0, max]}…" : s
end

SENSITIVE_KEYS = Set{"api_key", "password", "secret", "token", "key"}

def sensitive?(key : String) : Bool
  k = key.downcase
  SENSITIVE_KEYS.any? { |s| k.includes?(s) }
end

def redact_db_url(url : String) : String
  url.gsub(/(:\/\/[^:]+:)[^@]+(@)/, "\\1***\\2")
end

def summarize(data : JSON::Any) : String
  return "" unless data.as_h?
  parts = [] of String
  data.as_h.each do |k, v|
    next if k == "action"
    val = if sensitive?(k)
            "***"
          else
            case raw = v.raw
            when String
              display = k == "db" ? redact_db_url(raw) : raw
              %("#{truncate(display, 40)}")
            when Array then "[#{raw.size}]"
            when Hash  then "{…}"
            else            raw.to_s
            end
          end
    parts << "#{k}=#{val}"
  end
  parts.join(" ")
end

arcana_host = ENV["ARCANA_HOST"]? || "127.0.0.1"
arcana_port = (ENV["ARCANA_PORT"]? || "19118").to_i
config_path = ENV["MEMO_NAMESPACES"]? || "/etc/memo/namespaces.yaml"
max_concurrency = (ENV["MEMO_MAX_CONCURRENCY"]? || "32").to_i
save_interval = (ENV["MEMO_SAVE_INTERVAL"]? || "60").to_i

namespaces = Memo::Namespaces.new
if File.exists?(config_path)
  namespaces.load_config(config_path)
end

# Startup banner
STDERR.puts ""
STDERR.puts "#{BOLD}#{CYAN}memo-arcana#{RESET} #{DIM}— semantic search service#{RESET}"
STDERR.puts "#{DIM}┌──────────────────────────────────────────────────#{RESET}"
STDERR.puts "#{DIM}│#{RESET} config     #{DIM}│#{RESET} #{File.exists?(config_path) ? config_path : "(none)"}"
STDERR.puts "#{DIM}│#{RESET} namespaces #{DIM}│#{RESET} #{namespaces.configs.size} registered"
STDERR.puts "#{DIM}│#{RESET} bus        #{DIM}│#{RESET} #{arcana_host}:#{arcana_port}"
STDERR.puts "#{DIM}│#{RESET} requests   #{DIM}│#{RESET} up to #{max_concurrency} at once"
STDERR.puts "#{DIM}│#{RESET} saves      #{DIM}│#{RESET} every #{save_interval}s (changed indexes)"
STDERR.puts "#{DIM}└──────────────────────────────────────────────────#{RESET}"

namespaces.configs.each_value do |c|
  log "#{DIM}registered#{RESET} ns=#{BOLD}#{c.ns}#{RESET} #{DIM}db=#{truncate(c.db, 40)} preload=#{c.preload}#{RESET}"
end
namespaces.preload_all
namespaces.services.each_key do |ns|
  log "#{GREEN}●#{RESET} preloaded #{BOLD}#{ns}#{RESET}"
end

handler = Memo::ArcanaService.new(namespaces)

# Arcana::Client gives us join + correlation tracking + request/reply.
# The same client is shared with Memo::Providers::Bus for outbound
# embedding calls (bus/openai, bus/voyage formats).
client = Arcana::Client.new(
  url: "ws://#{arcana_host}:#{arcana_port}/bus",
  address: "memo:rag",
  name: "Memo RAG",
  description: "Multi-namespace retrieval-augmented generation service: semantic search, vector storage, embeddings",
  tags: ["rag", "search", "vectors", "embeddings"],
)
Memo::Providers::Bus.client = client

# Requests run concurrently, up to max_concurrency at a time. The client
# calls on_message from its WebSocket read loop, so handling a request there
# would hold up every other request, and the replies that memo's own bus
# calls (the bus/* embedding formats) are waiting for.
slots = Channel(Nil).new(max_concurrency)
client.on_message do |envelope|
  spawn do
    slots.send(nil)
    begin
      handle_request(client, handler, envelope)
    ensure
      slots.receive
    end
  end
end

# Save changed indexes periodically, so a crash leaves little for the
# journal to replay on the next start.
spawn do
  loop do
    sleep save_interval.seconds
    namespaces.open_services.each do |ns, svc|
      svc.save_index
    rescue ex
      log "#{RED}error#{RESET}      saving #{ns} index: #{ex.message}"
    end
  end
end

# Answer one request envelope.
def handle_request(client : Arcana::Client, handler : Memo::ArcanaService, envelope : Arcana::Envelope)
  payload = envelope.payload

  # A reply (result, need, help, error) isn't a request: e.g. an embedding
  # reply that arrived after memo stopped waiting for it. Answering it with
  # an error could start an error ping-pong with the sender.
  status = payload.as_h? ? Arcana::Protocol.status(payload) : nil
  if status && status != "request"
    log "#{DIM}ignored    #{envelope.from.ljust(12)} unexpected #{status} reply#{RESET}"
    return
  end

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
      help_payload = JSON.parse(%({"_proto":"arcana/1","_status":"help","guide":#{Memo::ArcanaService::GUIDE.to_json},"schema":#{Memo::ArcanaService::SCHEMA.to_json}}))
      client.send(envelope.reply(from: "memo:rag", payload: help_payload))
      return
    end

    result = handler.handle(data)
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

    client.send(envelope.reply(from: "memo:rag", payload: result_payload))
  rescue ex
    error_payload = JSON::Any.new({
      "_proto"  => JSON::Any.new("arcana/1"),
      "_status" => JSON::Any.new("error"),
      "message" => JSON::Any.new(ex.message || "Unknown error"),
    } of String => JSON::Any)
    begin
      client.send(envelope.reply(from: "memo:rag", payload: error_payload))
    rescue
      # client may be closed
    end
    log "#{RED}error#{RESET}      #{ex.message}"
  end
end

log "#{GREEN}●#{RESET} registered as #{BOLD}memo:rag#{RESET}, listening for requests"
STDERR.puts ""

Signal::INT.trap do
  STDERR.puts ""
  log "#{YELLOW}●#{RESET} shutting down"
  namespaces.close_all
  client.close
  exit 0
end

Signal::TERM.trap do
  namespaces.close_all
  client.close
  exit 0
end

client.connect
