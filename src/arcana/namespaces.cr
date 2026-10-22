require "wait_group"
require "../memo"
require "../memo/pg"
require "./bus_log"

module Memo
  # Registry of Memo::Service instances keyed by namespace (ns).
  #
  # Each ns has its own database, embedding service, and USearch index —
  # providing true isolation between projects sharing one memo-arcana
  # process.
  #
  # Namespaces are listed in a config file (some preloaded at boot), or
  # registered with `open` when allow_open is set. Once opened, services
  # are cached in memory until explicitly closed (or the process exits).
  class Namespaces
    # Configuration for a single namespace
    struct Config
      getter ns : String
      getter db : String
      getter service : String?
      getter format : String?
      getter api_key : String?
      getter model : String?
      getter index_dir : String?
      getter chunking_max_tokens : Int32
      getter preload : Bool
      # Whether to fall back to MEMO_API_KEY or OPENAI_API_KEY when api_key
      # isn't set. Only the config file's namespaces do: a namespace opened
      # over the bus names its own database, whose stored base_url could
      # send the key anywhere.
      getter? env_api_key : Bool

      def initialize(
        @ns : String,
        @db : String,
        @service : String? = nil,
        @format : String? = nil,
        @api_key : String? = nil,
        @model : String? = nil,
        @index_dir : String? = nil,
        @chunking_max_tokens : Int32 = 2000,
        @preload : Bool = false,
        @env_api_key : Bool = false,
      )
      end
    end

    getter configs : Hash(String, Config)
    getter services : Hash(String, Memo::Service)

    # Whether `open` may register a namespace the config file doesn't list.
    # Off by default, since the requester picks the database.
    property? allow_open : Bool = false

    def initialize
      @configs = {} of String => Config
      @services = {} of String => Memo::Service
      @mutex = Mutex.new
      @open_locks = {} of String => Mutex
      @in_flight = {} of String => WaitGroup
    end

    # Register a namespace config (without opening).
    def register(config : Config)
      @mutex.synchronize do
        @configs[config.ns] = config
      end
    end

    # Register and immediately open a namespace. Returns the Service.
    #
    # A namespace already registered keeps its settings: opening it again
    # with the same database just opens it, and with another one raises.
    # Registering a new one needs allow_open, and it's dropped again if it
    # fails to open, so a corrected open can follow.
    def open(config : Config) : Memo::Service
      added = @mutex.synchronize do
        if existing = @configs[config.ns]?
          raise "namespace '#{config.ns}' is already registered with another database" unless existing.db == config.db
          false
        else
          raise "namespace '#{config.ns}' isn't configured, and memo-arcana doesn't allow opening others (MEMO_BUS_OPEN)" unless @allow_open
          @configs[config.ns] = config
          true
        end
      end

      begin
        get(config.ns)
      rescue ex
        @mutex.synchronize { @configs.delete(config.ns) if @configs[config.ns]? == config } if added
        raise ex
      end
    end

    # Get the Memo::Service for a namespace, opening it lazily if needed.
    # Raises if the namespace isn't registered.
    #
    # Opening can be slow (it may replay or rebuild the index), so it holds
    # only that namespace's open lock; requests for other namespaces carry on.
    def get(ns : String) : Memo::Service
      @mutex.synchronize do
        if svc = @services[ns]?
          return svc
        end
        raise "namespace not registered: #{ns}" unless @configs.has_key?(ns)
      end

      open_lock(ns).synchronize do
        # Another request may have opened it while this one waited
        @mutex.synchronize { @services[ns]? } || open_service(ns)
      end
    end

    # Run the block with the namespace's service, opening it if needed.
    # close waits for blocks already running before it closes the service.
    def use(ns : String, &)
      svc, in_flight = enter(ns)
      begin
        yield svc
      ensure
        in_flight.done
      end
    end

    # Close and remove a namespace. Waits for an open in progress, and for
    # requests already using the service (see use). New requests wait, then
    # open it afresh.
    def close(ns : String) : Bool
      return false unless @mutex.synchronize { @configs.has_key?(ns) }

      open_lock(ns).synchronize do
        svc, in_flight = @mutex.synchronize { {@services.delete(ns), @in_flight.delete(ns)} }
        in_flight.try(&.wait)
        svc.try(&.close)
        !svc.nil?
      end
    end

    # List all registered namespaces with their open status.
    def list : Array({String, Bool})
      @mutex.synchronize do
        @configs.keys.map { |ns| {ns, @services.has_key?(ns)} }
      end
    end

    # Snapshot of the open services, for work done outside the lock
    # (e.g. periodic index saves).
    def open_services : Array({String, Memo::Service})
      @mutex.synchronize { @services.to_a }
    end

    # Preload all namespaces marked with preload: true in their config.
    def preload_all
      to_preload = @configs.values.select(&.preload).map(&.ns)
      to_preload.each do |ns|
        begin
          get(ns)
        rescue ex
          STDERR.puts "memo-arcana: failed to preload '#{ns}': #{BusLog.redact_db_url(ex.message.to_s)}"
        end
      end
    end

    # Close all open services (called on shutdown), each after its
    # in-flight requests finish.
    def close_all
      @mutex.synchronize { @services.keys }.each { |ns| close(ns) }
    end

    # Load namespace configs from a YAML-ish config file.
    #
    # Format (very simple, one block per namespace):
    #
    #   namespaces:
    #     - ns: wow
    #       db: postgres://wow:wow@localhost/wow_dev
    #       service: openai
    #       preload: true
    #     - ns: notes
    #       db: /var/lib/memo/notes.db
    #       service: mock
    def load_config(path : String)
      return unless File.exists?(path)
      content = File.read(path)
      parse_config(content)
    end

    # Parse a simplified YAML-style namespaces config.
    # Supports one level of indent — each namespace is a dash-prefixed block.
    private def parse_config(content : String)
      current : Hash(String, String)? = nil
      content.each_line do |raw_line|
        line = raw_line.sub(/#.*$/, "").rstrip
        next if line.strip.empty?
        next if line.strip == "namespaces:"

        if line =~ /^\s*-\s*(\w+)\s*:\s*(.*)$/
          finalize_block(current)
          current = {$1 => $2.strip}
        elsif line =~ /^\s+(\w+)\s*:\s*(.*)$/
          if c = current
            c[$1] = $2.strip
          end
        end
      end
      finalize_block(current)
    end

    private def finalize_block(block : Hash(String, String)?)
      return unless block
      ns = expand_env(block["ns"]?) || return
      db = expand_env(block["db"]?) || return

      preload = case block["preload"]?.try(&.downcase)
                when "true", "yes", "1" then true
                else                         false
                end

      chunking = block["chunking_max_tokens"]?.try(&.to_i?) || 2000

      register(Config.new(
        ns: ns,
        db: db,
        service: expand_env(block["service"]?),
        format: expand_env(block["format"]?),
        api_key: expand_env(block["api_key"]?),
        model: expand_env(block["model"]?),
        index_dir: expand_env(block["index_dir"]?),
        chunking_max_tokens: chunking,
        preload: preload,
        env_api_key: true,
      ))
    end

    # Expand ${VAR} and $VAR references from process env.
    # Missing vars become empty strings.
    private def expand_env(value : String?) : String?
      return nil unless value
      value.gsub(/\$\{(\w+)\}|\$(\w+)/) do |_, match|
        name = match[1]? || match[2]
        name ? (ENV[name]? || "") : ""
      end
    end

    # The namespace's service, counted in flight. Retries if close removed
    # the service between get and counting.
    private def enter(ns : String) : {Memo::Service, WaitGroup}
      loop do
        svc = get(ns)
        in_flight = @mutex.synchronize do
          next nil unless @services[ns]?.try(&.same?(svc))
          (@in_flight[ns] ||= WaitGroup.new).tap(&.add(1))
        end
        return {svc, in_flight} if in_flight
      end
    end

    private def open_lock(ns : String) : Mutex
      @mutex.synchronize { @open_locks[ns] ||= Mutex.new }
    end

    # Build a namespace's Service and add it to the registry. Called with the
    # namespace's open lock held, not @mutex (building can be slow).
    private def open_service(ns : String) : Memo::Service
      config = @mutex.synchronize { @configs[ns]? } || raise "namespace not registered: #{ns}"

      # The mock service allows 100 tokens, so the default chunk size is too
      # big for it. Other namespaces keep the default, including one named
      # only by format, or by neither (the database's default service).
      chunking = config.chunking_max_tokens
      chunking = 100 if (config.service || config.format) == "mock" && chunking == 2000
      api_key = config.api_key
      api_key ||= ENV["MEMO_API_KEY"]? || ENV["OPENAI_API_KEY"]? if config.env_api_key?

      svc = Memo::Service.new(
        db_path: config.db,
        service: config.service,
        format: config.format,
        api_key: api_key,
        model: config.model,
        index_dir: config.index_dir,
        chunking_max_tokens: chunking,
      )
      r = svc.index_recovery
      if r.replayed > 0 || r.rebuilt > 0 || r.missing > 0
        STDERR.puts "memo-arcana: '#{ns}' index recovery: #{r.replayed} replayed, " \
                    "#{r.rebuilt} rebuilt, #{r.missing} missing (re-index to restore)"
      end
      @mutex.synchronize { @services[ns] = svc }
      svc
    end
  end
end
