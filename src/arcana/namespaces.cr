require "../memo"
require "../memo/pg"

module Memo
  # Registry of Memo::Service instances keyed by namespace (ns).
  #
  # Each ns has its own database, embedding service, and USearch index —
  # providing true isolation between projects sharing one memo-arcana
  # process.
  #
  # Namespaces can be opened explicitly via `open` or listed in a config
  # file for preloading at boot. Once opened, services are cached in
  # memory until explicitly closed (or the process exits).
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

      def initialize(
        @ns : String,
        @db : String,
        @service : String? = nil,
        @format : String? = nil,
        @api_key : String? = nil,
        @model : String? = nil,
        @index_dir : String? = nil,
        @chunking_max_tokens : Int32 = 2000,
        @preload : Bool = false
      )
      end
    end

    getter configs : Hash(String, Config)
    getter services : Hash(String, Memo::Service)

    def initialize
      @configs = {} of String => Config
      @services = {} of String => Memo::Service
      @mutex = Mutex.new
      @open_locks = {} of String => Mutex
    end

    # Register a namespace config (without opening).
    def register(config : Config)
      @mutex.synchronize do
        @configs[config.ns] = config
      end
    end

    # Register and immediately open a namespace. Returns the Service.
    def open(config : Config) : Memo::Service
      register(config)
      get(config.ns)
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

    # Close and remove a namespace. Waits for an open in progress.
    def close(ns : String) : Bool
      return false unless @mutex.synchronize { @configs.has_key?(ns) }

      open_lock(ns).synchronize do
        svc = @mutex.synchronize { @services.delete(ns) }
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
          STDERR.puts "memo-arcana: failed to preload '#{ns}': #{ex.message}"
        end
      end
    end

    # Close all open services (called on shutdown).
    def close_all
      @mutex.synchronize do
        @services.each_value(&.close)
        @services.clear
      end
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
                else                          false
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

    private def open_lock(ns : String) : Mutex
      @mutex.synchronize { @open_locks[ns] ||= Mutex.new }
    end

    # Build a namespace's Service and add it to the registry. Called with the
    # namespace's open lock held, not @mutex (building can be slow).
    private def open_service(ns : String) : Memo::Service
      config = @mutex.synchronize { @configs[ns]? } || raise "namespace not registered: #{ns}"

      service_name = config.service || "mock"
      chunking = config.chunking_max_tokens
      chunking = 100 if service_name == "mock" && chunking == 2000

      svc = Memo::Service.new(
        db_path: config.db,
        service: config.service,
        format: config.format,
        api_key: config.api_key || ENV["MEMO_API_KEY"]? || ENV["OPENAI_API_KEY"]?,
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
