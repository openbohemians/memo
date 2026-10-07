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
# Environment variables:
#   ARCANA_HOST           — Arcana server host (default: 127.0.0.1)
#   ARCANA_PORT           — Arcana server port (default: 19118)
#   MEMO_NAMESPACES       — Path to namespaces config (default: /etc/memo/namespaces.yaml)
#   MEMO_MAX_CONCURRENCY  — Requests handled at once (default: 32)
#   MEMO_SAVE_INTERVAL    — Seconds between checks for an index save that's due (default: 60)

include Memo::BusLog

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
STDERR.puts "#{DIM}│#{RESET} saves      #{DIM}│#{RESET} checked every #{save_interval}s (due after 10,000 changes or 5 min)"
STDERR.puts "#{DIM}└──────────────────────────────────────────────────#{RESET}"

namespaces.configs.each_value do |c|
  log "#{DIM}registered#{RESET} ns=#{BOLD}#{c.ns}#{RESET} #{DIM}db=#{truncate(c.db, 40)} preload=#{c.preload}#{RESET}"
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

listener = Memo::ArcanaListener.new(client, namespaces, max_concurrency)
listener.listen
listener.save_periodically(save_interval.seconds)

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
