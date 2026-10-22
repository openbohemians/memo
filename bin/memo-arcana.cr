require "../src/arcana/listener"
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
# It won't start while another memo-arcana serves memo:rag, and it
# rejoins the bus whenever the connection drops.
#
# Environment variables:
#   ARCANA_HOST           — Arcana server host (default: 127.0.0.1)
#   ARCANA_PORT           — Arcana server port (default: 19118)
#   MEMO_NAMESPACES       — Path to namespaces config (default: /etc/memo/namespaces.yaml)
#   MEMO_MAX_CONCURRENCY  — Requests handled at once (default: 32)
#   MEMO_MAX_WAITING      — Requests waiting for a turn before memo answers "busy" (default: 8x concurrency)
#   MEMO_SAVE_INTERVAL    — Seconds between checks for an index save that's due (default: 60)
#   MEMO_BUS_OPEN         — Set to 1 to let `open` requests register namespaces the config
#                           doesn't list (default: off; they pick their own database)

include Memo::BusLog

# Exit if another memo-arcana already serves memo:rag
def exit_if_already_running(host : String, port : Int32, namespaces : Memo::Namespaces) : Nil
  return unless Memo::ArcanaListener.already_running?(host, port)
  log "#{RED}●#{RESET} another memo-arcana already serves #{BOLD}memo:rag#{RESET} on #{host}:#{port}; " \
      "joining too would take it off the bus when either one stops, so stop that one first"
  namespaces.close_all
  exit 1
end

# Log once the client's connection is up (`connect` blocks while it lasts)
def log_when_joined(client : Arcana::Client) : Nil
  spawn do
    40.times do
      sleep 50.milliseconds
      if client.connected?
        log "#{GREEN}●#{RESET} joined the bus as #{BOLD}memo:rag#{RESET}, listening for requests"
        break
      end
    end
  end
end

arcana_host = ENV["ARCANA_HOST"]? || "127.0.0.1"
arcana_port = (ENV["ARCANA_PORT"]? || "19118").to_i
config_path = ENV["MEMO_NAMESPACES"]? || "/etc/memo/namespaces.yaml"
max_concurrency = (ENV["MEMO_MAX_CONCURRENCY"]? || "32").to_i
max_waiting = (ENV["MEMO_MAX_WAITING"]?.try(&.to_i?)) || max_concurrency * 8
save_interval = (ENV["MEMO_SAVE_INTERVAL"]? || "60").to_i

namespaces = Memo::Namespaces.new
namespaces.allow_open = {"1", "true", "yes"}.includes?(ENV["MEMO_BUS_OPEN"]?.try(&.downcase))
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
STDERR.puts "#{DIM}│#{RESET} bus open   #{DIM}│#{RESET} #{namespaces.allow_open? ? "allowed (MEMO_BUS_OPEN)" : "off: namespaces come from the config"}"
STDERR.puts "#{DIM}│#{RESET} requests   #{DIM}│#{RESET} up to #{max_concurrency} at once, #{max_waiting} waiting"
STDERR.puts "#{DIM}│#{RESET} saves      #{DIM}│#{RESET} checked every #{save_interval}s (due after 10,000 changes or 5 min)"
STDERR.puts "#{DIM}└──────────────────────────────────────────────────#{RESET}"

exit_if_already_running(arcana_host, arcana_port, namespaces)

namespaces.configs.each_value do |c|
  log "#{DIM}registered#{RESET} ns=#{BOLD}#{c.ns}#{RESET} #{DIM}db=#{truncate(redact_db_url(c.db), 40)} preload=#{c.preload}#{RESET}"
end
namespaces.preload_all
namespaces.services.each_key do |ns|
  log "#{GREEN}●#{RESET} preloaded #{BOLD}#{ns}#{RESET}"
end

# Arcana::Client gives us join + correlation tracking + request/reply.
# The same client is shared with Memo::Providers::Bus for outbound
# embedding calls (bus/openai, bus/voyage formats).
client = Arcana::Client.new(
  url: "ws://#{arcana_host}:#{arcana_port}/bus",
  address: Memo::ArcanaListener::ADDRESS,
  name: "Memo RAG",
  description: "Multi-namespace retrieval-augmented generation service: semantic search, vector storage, embeddings",
  tags: ["rag", "search", "vectors", "embeddings"],
)
Memo::Providers::Bus.client = client

listener = Memo::ArcanaListener.new(client, namespaces, max_concurrency, max_waiting)
listener.listen
listener.save_periodically(save_interval.seconds)

stopping = false

Signal::INT.trap do
  stopping = true
  STDERR.puts ""
  log "#{YELLOW}●#{RESET} shutting down"
  namespaces.close_all
  client.close
  exit 0
end

Signal::TERM.trap do
  stopping = true
  namespaces.close_all
  client.close
  exit 0
end

# Join the bus, and rejoin whenever the connection drops (a bus restart,
# say), waiting 1 s at first and up to 30 s while the bus can't be
# reached. Another memo-arcana may have taken memo:rag meanwhile, so each
# rejoin is checked first.
retry_delay = 1.second
rejoining = false
loop do
  exit_if_already_running(arcana_host, arcana_port, namespaces) if rejoining
  log_when_joined(client)
  joined_at = Time.instant
  begin
    client.connect
    break if stopping
    log "#{YELLOW}●#{RESET} lost the bus"
  rescue ex
    break if stopping
    log "#{RED}●#{RESET} can't reach the bus at #{arcana_host}:#{arcana_port}: #{ex.message}"
  end
  retry_delay = 1.second if Time.instant - joined_at > 1.minute
  log "#{DIM}rejoining in #{retry_delay.total_seconds.to_i}s#{RESET}"
  sleep retry_delay
  retry_delay = {retry_delay * 2, 30.seconds}.min
  rejoining = true
end
