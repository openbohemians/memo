module Memo
  # Statistics about indexed content
  struct Stats
    getter embeddings : Int64
    getter chunks : Int64
    getter sources : Int64
    getter index_memory_bytes : UInt64
    getter query_cache_size : Int32

    def initialize(@embeddings, @chunks, @sources, @index_memory_bytes = 0_u64, @query_cache_size = 0)
    end

    def index_memory_mb : Float64
      (@index_memory_bytes.to_f64 / (1024 * 1024)).round(1)
    end
  end

  # Document to be indexed
  #
  # Supports both integer and string source IDs:
  # - Int64: Time-based, sortable IDs (e.g., Unix timestamps)
  # - String: UUIDs and other text identifiers
  struct Document
    property source_type : String
    property source_id : ExternalId
    property text : String
    property pair_id : ExternalId?
    property parent_id : ExternalId?

    def initialize(
      @source_type : String,
      @source_id : ExternalId,
      @text : String,
      @pair_id : ExternalId? = nil,
      @parent_id : ExternalId? = nil,
    )
    end
  end

  # Main service class for semantic search operations
  #
  # Encapsulates configuration and provides clean API for indexing and search.
  #
  # ## Quick Start
  #
  # ```
  # # Initialize with default service (mock, preloaded)
  # memo = Memo::Service.new(db_path: "/var/data/memo.db")
  #
  # # Configure a real service
  # memo.create_service(
  #   name: "openai",
  #   format: "openai",
  #   model: "text-embedding-3-small",
  #   dimensions: 1536,
  #   max_tokens: 8191
  # )
  # memo.set_default_service("openai")
  #
  # # Switch to it
  # memo.use_service("openai", api_key: ENV["OPENAI_API_KEY"])
  #
  # # Index documents
  # memo.index(source_type: "event", source_id: 123, text: "Document text...")
  #
  # # Search
  # results = memo.search(query: "search query", limit: 10)
  #
  # # Clean up
  # memo.close
  # ```
  #
  # ## Service Configuration
  #
  # Services are named configurations for embedding providers:
  #
  # ```
  # memo.create_service(
  #   name: "azure-prod",
  #   format: "openai",
  #   base_url: "https://mycompany.openai.azure.com/",
  #   model: "text-embedding-ada-002",
  #   dimensions: 1536,
  #   max_tokens: 8191
  # )
  #
  # # Switch services at runtime
  # memo.use_service("azure-prod", api_key: ENV["AZURE_API_KEY"])
  # ```
  #
  # ## Database
  #
  # Memo stores all data in a single SQLite file at the provided `db_path`.
  # Contains: services, embeddings, chunks, texts, queue
  #
  class Service
    getter db : DB::Database
    getter provider : Providers::Base
    getter service_id : Int64
    getter service_name : String
    getter chunking_config : Config::Chunking
    getter queue_config : Config::Queue
    getter dimensions : Int32
    getter batch_size : Int32
    getter usearch_index : USearch::Index
    getter service_format : String
    getter service_model : String
    getter db_path : String?
    getter index_path : String
    getter query_cache : QueryCache

    # What opening the index took (journal replay, rebuild, missing vectors)
    getter index_recovery : IndexJournal::Recovery

    # Private struct for init_provider return value
    private record ProviderConfig,
      provider : Providers::Base,
      service_id : Int64,
      service_name : String,
      format : String,
      model : String,
      dimensions : Int32,
      max_tokens : Int32,
      tokens_per_byte : Float64

    # Track whether we own the db connection (for close behavior)
    @owns_db : Bool = true

    # Held for a write transaction plus applying its index changes, and for
    # saving the index, so a save never checkpoints a committed change the
    # in-memory index hasn't applied yet.
    @write_lock = Mutex.new

    # Set when applying committed changes to the index failed. The journal
    # still has them; saves skip the checkpoint so they replay on next open.
    @index_out_of_step = false

    # Index changes applied since the last save, and when that was. A save
    # rewrites the whole index file, so memo saves on a policy (see
    # save_index_if_due) rather than after every change; the journal
    # replays whatever is unsaved after a crash, ~4 ms per change.
    @unsaved_changes = 0
    @saved_at = Time.instant
    @save_scheduled = false

    # Save once this many index changes are unsaved, or once any have been
    # unsaved this long
    getter index_save_changes : Int32 = 10_000
    getter index_save_interval : Time::Span = 5.minutes

    # Track whether text storage is enabled
    getter? text_storage : Bool = false

    # Track whether vocab building is enabled
    getter? build_vocab : Bool = false

    # Initialize service with database path
    #
    # Use EITHER:
    # - service: Name of pre-configured service (from ServiceProvider.create)
    # - format: API format ("openai", "mock") to configure inline
    #
    # Required:
    # - db_path: Full path to database file (e.g., "/var/data/memo.db")
    # - api_key: API key (not needed for mock format)
    #
    # Optional:
    # - service: Name of pre-configured service to use
    # - format: API format for inline configuration (default "openai")
    # - base_url: Custom API endpoint (for OpenAI-compatible APIs)
    # - model: Embedding model (default depends on format)
    # - dimensions: Vector dimensions (auto-detected from model)
    # - max_tokens: Token limit (auto-detected from model)
    # - store_text: Enable text storage in texts table (default true)
    # - build_vocab: Enable incremental vocabulary building (default true, requires store_text)
    # - chunking_max_tokens: Max tokens per chunk (default 2000)
    #
    # Example:
    # ```
    # memo = Memo::Service.new(
    #   db_path: "/var/data/memo.db",
    #   format: "openai",
    #   api_key: ENV["OPENAI_API_KEY"]
    # )
    # ```
    def initialize(
      db_path : String,
      api_key : String? = nil,
      service : String? = nil,
      format : String? = nil,
      base_url : String? = nil,
      model : String? = nil,
      dimensions : Int32? = nil,
      max_tokens : Int32? = nil,
      chunking_max_tokens : Int32 = 2000,
      store_text : Bool = true,
      build_vocab : Bool = true,
      batch_size : Int32 = 100,
      max_retries : Int32 = 3,
      index_dir : String? = nil,
      query_cache_size : Int32 = 10_000,
      persistent_query_cache : Bool = true,
      track_matches : Bool = true,
      @index_save_changes : Int32 = 10_000,
      @index_save_interval : Time::Span = 5.minutes,
    )
      # Detect backend from connection string
      if db_path.starts_with?("postgres")
        # PostgreSQL: connect directly, set dialect and queries
        @db = DB.open(db_path)
        @db.memo_dialect = Dialect.for(db_path)
        @db.memo_queries = Queries.for(@db, db_path)
        @db_path = nil
        # Default index dir for PG if not provided
        index_dir ||= USearchIndex::DEFAULT_INDEX_DIR
      else
        # SQLite: create parent directory and connect
        dir = File.dirname(db_path)
        Dir.mkdir_p(dir) unless dir.empty? || Dir.exists?(dir)
        @db = DB.open(Database.sqlite_url(db_path))
        @db_path = db_path
      end

      @owns_db = true
      @track_matches = track_matches
      @text_storage = store_text
      @build_vocab = build_vocab && store_text # vocab requires text storage

      # Initialize schema
      Database.init(@db)

      # Initialize from service name or format
      config = init_provider(
        service: service,
        format: format,
        base_url: base_url,
        model: model,
        dimensions: dimensions,
        max_tokens: max_tokens,
        api_key: api_key,
        chunking_max_tokens: chunking_max_tokens
      )

      @provider = config.provider
      @service_id = config.service_id
      @service_name = config.service_name
      @service_format = config.format
      @service_model = config.model
      @dimensions = config.dimensions

      # Compute and open USearch HNSW index for this service
      @index_path = if idx_dir = index_dir
                      USearchIndex.index_path_in_dir(idx_dir, config.format, config.model, config.dimensions)
                    else
                      USearchIndex.index_path(db_path, config.format, config.model, config.dimensions)
                    end
      @usearch_index, @index_recovery, @index_lock = IndexJournal.open(@db, @index_path, config.dimensions, @service_id)

      # Create chunking config with service's tokens_per_byte ratio
      @chunking_config = Config::Chunking.new(
        min_tokens: 100,
        max_tokens: chunking_max_tokens,
        no_chunk_threshold: chunking_max_tokens,
        tokens_per_byte: config.tokens_per_byte
      )

      # Store batch size and queue config
      @batch_size = batch_size
      @queue_config = Config::Queue.new(max_retries: max_retries)

      # Query embedding cache
      @query_cache = QueryCache.new(
        max_entries: query_cache_size,
        db: persistent_query_cache ? @db : nil,
        service_id: @service_id
      )
    end

    # Initialize service with existing database connection
    #
    # Use this when caller manages the connection lifecycle.
    # Caller is responsible for closing the connection.
    #
    # The db_path is queried from the database for CLI use. Pass db_path
    # explicitly if the pragma query doesn't work for your setup.
    def initialize(
      db : DB::Database,
      api_key : String? = nil,
      service : String? = nil,
      format : String? = nil,
      base_url : String? = nil,
      model : String? = nil,
      dimensions : Int32? = nil,
      max_tokens : Int32? = nil,
      chunking_max_tokens : Int32 = 2000,
      store_text : Bool = true,
      build_vocab : Bool = true,
      batch_size : Int32 = 100,
      max_retries : Int32 = 3,
      db_path : String? = nil,
      index_dir : String? = nil,
      query_cache_size : Int32 = 10_000,
      persistent_query_cache : Bool = true,
      track_matches : Bool = true,
      @index_save_changes : Int32 = 10_000,
      @index_save_interval : Time::Span = 5.minutes,
    )
      @db = db
      @owns_db = false # Caller owns the connection
      @track_matches = track_matches
      @text_storage = store_text
      @build_vocab = build_vocab && store_text # vocab requires text storage

      # Get db path from dialect if not provided
      @db_path = db_path || @db.memo_dialect.db_file_path(@db)

      Database.init(@db)

      # Initialize from service name or format
      config = init_provider(
        service: service,
        format: format,
        base_url: base_url,
        model: model,
        dimensions: dimensions,
        max_tokens: max_tokens,
        api_key: api_key,
        chunking_max_tokens: chunking_max_tokens
      )

      @provider = config.provider
      @service_id = config.service_id
      @service_name = config.service_name
      @service_format = config.format
      @service_model = config.model
      @dimensions = config.dimensions

      # Compute and open USearch HNSW index for this service
      @index_path = if idx_dir = index_dir
                      USearchIndex.index_path_in_dir(idx_dir, config.format, config.model, config.dimensions)
                    elsif resolved_db_path = @db_path
                      USearchIndex.index_path(resolved_db_path, config.format, config.model, config.dimensions)
                    else
                      USearchIndex.index_path_in_dir(USearchIndex::DEFAULT_INDEX_DIR, config.format, config.model, config.dimensions)
                    end
      @usearch_index, @index_recovery, @index_lock = IndexJournal.open(@db, @index_path, config.dimensions, @service_id)

      # Create chunking config with service's tokens_per_byte ratio
      @chunking_config = Config::Chunking.new(
        min_tokens: 100,
        max_tokens: chunking_max_tokens,
        no_chunk_threshold: chunking_max_tokens,
        tokens_per_byte: config.tokens_per_byte
      )

      # Store batch size and queue config
      @batch_size = batch_size
      @queue_config = Config::Queue.new(max_retries: max_retries)

      # Query embedding cache
      @query_cache = QueryCache.new(
        max_entries: query_cache_size,
        db: persistent_query_cache ? @db : nil,
        service_id: @service_id
      )
    end

    # Index a document
    #
    # Enqueues the document and processes it immediately with retry support.
    # Returns number of chunks successfully stored.
    #
    # Supports both integer and string source IDs:
    # - Int64: Time-based, sortable IDs (e.g., Unix timestamps)
    # - String: UUIDs and other text identifiers
    #
    # When source_id is nil, memo creates and manages the source internally.
    # Useful for CLI and cases where external ID correlation isn't needed.
    def index(
      source_type : String,
      source_id : ExternalId?,
      text : String,
      pair_id : ExternalId? = nil,
      parent_id : ExternalId? = nil,
    ) : Int32
      # Resolve or create source ID
      internal_source_id = if sid = source_id
                             SourceRegistry.resolve(@db, source_type, sid)
                           else
                             SourceRegistry.create(@db, source_type)
                           end
      internal_pair_id = if pid = pair_id
                           SourceRegistry.resolve(@db, source_type, pid)
                         else
                           nil
                         end
      internal_parent_id = if pid = parent_id
                             SourceRegistry.resolve(@db, source_type, pid)
                           else
                             nil
                           end

      enqueue_internal(
        source_type: source_type,
        internal_source_id: internal_source_id,
        text: text,
        internal_pair_id: internal_pair_id,
        internal_parent_id: internal_parent_id
      )
      process_queue_item_internal(internal_source_id)
    end

    # Index a document (Document overload)
    #
    # Convenience method that accepts a Document struct.
    def index(doc : Document) : Int32
      index(
        source_type: doc.source_type,
        source_id: doc.source_id,
        text: doc.text,
        pair_id: doc.pair_id,
        parent_id: doc.parent_id
      )
    end

    # Index multiple documents in a batch
    #
    # Enqueues all documents and processes them with retry support.
    # More efficient than calling index() multiple times.
    #
    # Returns total number of documents successfully processed.
    def index_batch(docs : Array(Document)) : Int32
      return 0 if docs.empty?

      enqueue_batch(docs)
      process_queue
    end

    # Search for semantically similar chunks
    #
    # Automatically generates query embedding and searches.
    #
    # Returns array of search results ranked by similarity.
    #
    # source_id: Filter by external source ID (Int64 or String).
    #
    # like: LIKE pattern(s) to filter by text content.
    #   Single string or array of strings for AND filtering.
    #   Example: like: "%cats%" or like: ["%cats%", "%dogs%"]
    #   Only works when text storage is enabled.
    #
    # match: FTS5 full-text search query.
    #   Supports AND, OR, NOT, prefix*, "phrases".
    #   Example: match: "cats OR dogs", match: "quick brown*"
    #   Only works when text storage is enabled.
    #
    # sql_where: Raw SQL fragment for filtering chunks. Used with ATTACH
    #   to filter by external database tables.
    #   Example: "c.source_id IN (SELECT id FROM main.artifact WHERE kind = 'goal')"
    #   Note: c.source_id here is the internal ID, not external.
    #
    # include_text: If true, includes text content in search results.
    #   Only works when text storage is enabled.
    def search(
      query : String,
      limit : Int32 = 10,
      min_score : Float64 = 0.7,
      source_type : String? = nil,
      source_id : ExternalId? = nil,
      pair_id : ExternalId? = nil,
      parent_id : ExternalId? = nil,
      like : String | Array(String) | Nil = nil,
      match : String? = nil,
      sql_where : String? = nil,
      include_text : Bool = true,
      sql_where_args : Array(DB::Any) = [] of DB::Any,
    ) : Array(Search::Result)
      results, _timings = search_with_timings(
        query: query, limit: limit, min_score: min_score,
        source_type: source_type, source_id: source_id,
        pair_id: pair_id, parent_id: parent_id,
        like: like, match: match, sql_where: sql_where,
        include_text: include_text, sql_where_args: sql_where_args
      )
      results
    end

    # Search with per-stage timing breakdown
    #
    # Returns {results, timings} where timings has embed_ms, search_ms, fetch_ms, total_ms.
    def search_with_timings(
      query : String,
      limit : Int32 = 10,
      min_score : Float64 = 0.7,
      source_type : String? = nil,
      source_id : ExternalId? = nil,
      pair_id : ExternalId? = nil,
      parent_id : ExternalId? = nil,
      like : String | Array(String) | Nil = nil,
      match : String? = nil,
      sql_where : String? = nil,
      include_text : Bool = true,
      sql_where_args : Array(DB::Any) = [] of DB::Any,
    ) : {Array(Search::Result), Search::Timings}
      t_start = Time.instant

      # Generate query embedding (check cache first)
      t_embed_start = Time.instant
      cached = @query_cache.get(query)
      if cached
        query_embedding, _tokens = cached
      else
        query_embedding, _tokens = @provider.embed_text(query, "query")
        @query_cache.put(query, query_embedding, _tokens)
      end
      t_embed_end = Time.instant

      # Resolve external IDs to internal IDs for filtering
      internal_source_id = source_id && source_type ? SourceRegistry.get_internal(@db, source_type, source_id) : nil
      internal_pair_id = pair_id && source_type ? SourceRegistry.get_internal(@db, source_type, pair_id) : nil
      internal_parent_id = parent_id && source_type ? SourceRegistry.get_internal(@db, source_type, parent_id) : nil

      filters = if source_type || internal_source_id || internal_pair_id || internal_parent_id
                  Search::Filters.new(
                    source_type: source_type,
                    internal_source_id: internal_source_id,
                    internal_pair_id: internal_pair_id,
                    internal_parent_id: internal_parent_id
                  )
                else
                  nil
                end

      like_patterns = case like
                      when String then [like]
                      when Array  then like
                      else             nil
                      end

      # Vector + metadata search
      t_search_start = Time.instant
      results = Search.semantic(
        db: @db,
        embedding: query_embedding,
        service_id: @service_id,
        usearch_index: @usearch_index,
        limit: limit,
        min_score: min_score,
        filters: filters,
        sql_where: sql_where,
        like: @text_storage ? like_patterns : nil,
        match: @text_storage ? match : nil,
        include_text: @text_storage && include_text,
        sql_where_args: sql_where_args, track_matches: @track_matches
      )
      t_end = Time.instant

      embed_ms = (t_embed_end - t_embed_start).total_milliseconds
      search_ms = (t_end - t_search_start).total_milliseconds
      total_ms = (t_end - t_start).total_milliseconds

      timings = Search::Timings.new(
        embed_ms: embed_ms.round(1),
        search_ms: search_ms.round(1),
        fetch_ms: (search_ms * 0.5).round(1), # approximate — fetch is part of semantic()
        total_ms: total_ms.round(1),
        cache_hit: !!cached
      )

      {results, timings}
    end

    # Mark chunks as read (increment read_count)
    def mark_as_read(chunk_ids : Array(Int64))
      Search.mark_as_read(@db, chunk_ids)
    end

    # Get statistics about indexed content
    #
    # Returns counts of embeddings, chunks, and unique sources.
    def stats : Stats
      q = @db.memo_queries
      Stats.new(
        q.count_service_embeddings(@service_id),
        q.count_service_chunks(@service_id),
        q.count_service_sources(@service_id),
        @usearch_index.memory_usage,
        @query_cache.size
      )
    end

    # Delete all chunks for a source
    #
    # Removes all chunks with the given source_id (and optionally source_type).
    # Orphaned embeddings (not referenced by any chunk) are also cleaned up.
    #
    # Returns number of chunks deleted.
    #
    # source_id: External source ID (Int64 or String).
    # source_type: Optional filter to only delete chunks with matching source_type.
    #   If nil and source_id is Int64, searches integer IDs across all types.
    #   If nil and source_id is String, searches string IDs across all types.
    def delete(source_id : ExternalId, source_type : String? = nil) : Int32
      # Resolve external ID to internal ID
      internal_id = if source_type
                      SourceRegistry.get_internal(@db, source_type, source_id)
                    else
                      SourceRegistry.get_internal_any_type(@db, source_id)
                    end

      return 0 unless internal_id

      deleted = 0
      write_transaction do |cnn, pending|
        deleted = delete_internal(cnn, pending, internal_id, source_type)
      end
      deleted
    end

    # Delete chunks by internal source ID
    #
    # Internal method used by delete() and embed_and_store(). Runs inside the
    # caller's transaction; index removals are queued on `pending`.
    private def delete_internal(
      cnn : DB::Connection,
      pending : USearchIndex::Pending,
      internal_source_id : Int64,
      source_type : String? = nil,
    ) : Int32
      q = cnn.memo_queries
      hashes = q.get_chunk_hashes(internal_source_id, source_type)

      deleted_count = 0

      hashes.each do |hash|
        deleted_count += if source_type
                           q.delete_chunks(hash, internal_source_id, source_type)
                         else
                           q.delete_chunks(hash, internal_source_id)
                         end
      end

      hashes.each do |hash|
        if q.count_chunks_by_hash(hash) == 0
          IndexJournal.record_removals(cnn, pending, hash, @service_id)
          q.delete_embeddings_by_hash(hash)
        end
      end

      delete_source_text_internal(internal_source_id, cnn)

      deleted_count
    end

    # Run the block in a database transaction, yielding its connection and a
    # queue for index changes. Statements in the block must use the
    # connection. Queued index changes are applied only once it commits.
    private def write_transaction(&)
      @write_lock.synchronize do
        pending = USearchIndex::Pending.new
        committed = false
        Memo::Database.transaction(@db) do |cnn|
          yield cnn, pending
          committed = true
        end
        next unless committed

        begin
          change_count = pending.size
          pending.apply(@usearch_index)
          @unsaved_changes += change_count
        rescue ex
          @index_out_of_step = true
          raise ex
        end
      end
      schedule_save if save_due?
    end

    private def save_due? : Bool
      return false if @unsaved_changes == 0
      @unsaved_changes >= @index_save_changes || Time.instant - @saved_at >= @index_save_interval
    end

    # Save in a separate fiber, so the write that made it due returns now
    private def schedule_save
      return if @save_scheduled
      @save_scheduled = true
      spawn do
        save_index_if_due
      rescue ex
        # Unsaved changes stay in the journal; the next due check retries
        STDERR.puts "memo: saving #{@index_path} failed: #{ex.message}"
      ensure
        @save_scheduled = false
      end
    end

    # Close database connection
    #
    # Should be called when done with service to free resources.
    # Safe to call multiple times.
    #
    # Note: If service was initialized with an existing db connection,
    # close is a no-op (caller owns the connection).
    def close
      begin
        save_index
      rescue
        # Unsaved index changes stay in the journal and replay on next open
      end
      @usearch_index.close
      @index_lock.close
      return unless @owns_db
      @db.close
    rescue
      # Already closed or other error - ignore
    end

    # Save the USearch index to disk and checkpoint the journal, now.
    #
    # Does nothing when the index hasn't changed since the last save. The
    # file is written on a separate thread: searches carry on meanwhile,
    # writes wait. close calls this; for routine saves prefer
    # save_index_if_due (memo also schedules those itself after writes).
    def save_index
      @write_lock.synchronize do
        next if @usearch_index.closed? || (@unsaved_changes == 0 && !@index_out_of_step)

        if @index_out_of_step
          USearchIndex.save_in_background(@usearch_index, @index_path)
        else
          IndexJournal.checkpoint(@db, @usearch_index, @service_id, @index_path)
        end
        @unsaved_changes = 0
        @saved_at = Time.instant
      end
    end

    # Save if the policy says it's time: index_save_changes unsaved changes,
    # or any unsaved for index_save_interval. Cheap to call often (e.g. after
    # each queue run, or from a timer).
    def save_index_if_due
      save_index if save_due?
    end

    # =========================================================================
    # Service Configuration CRUD
    # =========================================================================

    # Create a new service configuration
    #
    # Creates a named service configuration that can be used later with
    # Service.new(service: "name", ...).
    #
    # Example:
    # ```
    # memo.create_service(
    #   name: "azure-prod",
    #   format: "openai",
    #   base_url: "https://mycompany.openai.azure.com/",
    #   model: "text-embedding-ada-002",
    #   dimensions: 1536,
    #   max_tokens: 8191
    # )
    # ```
    def create_service(
      name : String,
      format : String,
      model : String,
      dimensions : Int32,
      max_tokens : Int32,
      base_url : String? = nil,
    ) : ServiceProvider::Info
      ServiceProvider.create(@db, name, format, model, dimensions, max_tokens, base_url)
    end

    # Get a service configuration by name
    #
    # Returns nil if not found.
    def get_service(name : String) : ServiceProvider::Info?
      ServiceProvider.get_by_name(@db, name)
    end

    # List all service configurations
    #
    # Returns array of service info, ordered by creation time (newest first).
    def list_services : Array(ServiceProvider::Info)
      ServiceProvider.list(@db)
    end

    # List service configurations by format
    #
    # Returns array of service info for the specified API format.
    def list_services_by_format(format : String) : Array(ServiceProvider::Info)
      ServiceProvider.list_by_format(@db, format)
    end

    # Update a service configuration
    #
    # Can update base_url and max_tokens.
    # Returns the updated service info, or nil if not found.
    def update_service(
      name : String,
      base_url : String? = nil,
      max_tokens : Int32? = nil,
    ) : ServiceProvider::Info?
      svc = ServiceProvider.get_by_name(@db, name)
      return nil unless svc
      ServiceProvider.update(@db, svc.id, base_url, max_tokens)
    end

    # Delete a service configuration
    #
    # By default, fails if the service has any associated embeddings.
    # Use force: true to delete the service and all associated data.
    #
    # Returns true if deleted, false if not found.
    def delete_service(name : String, force : Bool = false) : Bool
      svc = ServiceProvider.get_by_name(@db, name)
      return false unless svc
      result = ServiceProvider.delete(@db, svc.id, force)
      # Delete USearch index file if service was deleted
      if result
        svc_index_path = if db_p = @db_path
                           USearchIndex.index_path(db_p, svc.format, svc.model, svc.dimensions)
                         else
                           USearchIndex.index_path_in_dir(USearchIndex::DEFAULT_INDEX_DIR, svc.format, svc.model, svc.dimensions)
                         end
        USearchIndex.delete_file(svc_index_path)
      end
      result
    end

    # Get usage statistics for a service
    def service_stats(name : String) : ServiceProvider::Stats?
      svc = ServiceProvider.get_by_name(@db, name)
      return nil unless svc
      ServiceProvider.stats(@db, svc.id)
    end

    # Get the default service configuration
    def default_service : ServiceProvider::Info?
      ServiceProvider.get_default(@db)
    end

    # Set a service as the default
    #
    # Returns true if successful, false if service not found.
    def set_default_service(name : String) : Bool
      ServiceProvider.set_default(@db, name)
    end

    # Switch to a different service
    #
    # Changes the current provider and service configuration.
    # The api_key is required for non-mock services.
    #
    # Example:
    # ```
    # memo.use_service("azure-prod", api_key: ENV["AZURE_API_KEY"])
    # ```
    def use_service(name : String, api_key : String? = nil)
      svc = ServiceProvider.get_by_name(@db, name)
      raise ArgumentError.new("Service '#{name}' not found") unless svc

      # Create provider instance from stored config
      provider_instance = Providers::Registry.create(svc.format, api_key, svc.model, svc.base_url)
      raise ArgumentError.new("Unknown format: #{svc.format}") unless provider_instance

      # Save and close the current service's index
      save_index
      @usearch_index.close
      @index_lock.close

      @provider = provider_instance
      @service_name = name
      @service_id = svc.id
      @service_format = svc.format
      @service_model = svc.model
      @dimensions = svc.dimensions

      # Open USearch index for the new service
      @index_path = if db_p = @db_path
                      USearchIndex.index_path(db_p, svc.format, svc.model, svc.dimensions)
                    else
                      USearchIndex.index_path_in_dir(USearchIndex::DEFAULT_INDEX_DIR, svc.format, svc.model, svc.dimensions)
                    end
      @usearch_index, @index_recovery, @index_lock = IndexJournal.open(@db, @index_path, svc.dimensions, @service_id)
    end

    # =========================================================================
    # Queue Operations
    # =========================================================================

    # Queue statistics
    struct QueueStats
      getter pending : Int64
      getter failed : Int64

      def initialize(@pending, @failed)
      end
    end

    # Enqueue a document for later embedding
    #
    # Adds the document to the embed_queue table without embedding it.
    # Use process_queue to embed queued items.
    #
    # If the source is already in the queue, the text is updated.
    def enqueue(
      source_type : String,
      source_id : ExternalId,
      text : String,
      pair_id : ExternalId? = nil,
      parent_id : ExternalId? = nil,
    )
      # Resolve external IDs to internal IDs
      internal_source_id = SourceRegistry.resolve(@db, source_type, source_id)
      internal_pair_id = if pid = pair_id
                           SourceRegistry.resolve(@db, source_type, pid)
                         else
                           nil
                         end
      internal_parent_id = if pid = parent_id
                             SourceRegistry.resolve(@db, source_type, pid)
                           else
                             nil
                           end

      enqueue_internal(
        source_type: source_type,
        internal_source_id: internal_source_id,
        text: text,
        internal_pair_id: internal_pair_id,
        internal_parent_id: internal_parent_id
      )
    end

    # Internal enqueue using internal source IDs
    private def enqueue_internal(
      source_type : String,
      internal_source_id : Int64,
      text : String,
      internal_pair_id : Int64? = nil,
      internal_parent_id : Int64? = nil,
      db : DBHandle = @db,
    )
      now = Time.utc.to_unix_ms

      # Store source_type, pair_id and parent_id in the text field as metadata prefix
      # Format: "MEMO_META:source_type,pair_id,parent_id\n" followed by actual text
      stored_text = "MEMO_META:#{source_type},#{internal_pair_id || ""},#{internal_parent_id || ""}\n#{text}"

      db.memo_queries.enqueue(internal_source_id, stored_text, now)

      # Store text immediately so it's available for retrieval
      # before embedding runs. Embedding is deferred, text is not.
      # skip_hash: source_text_changed? treats NULL hash as "changed",
      # so process_queue will still embed this text later.
      if @text_storage
        store_source_text_internal(internal_source_id, text, skip_hash: true, db: db)
      end
    end

    # Enqueue a document (Document overload)
    def enqueue(doc : Document)
      enqueue(
        source_type: doc.source_type,
        source_id: doc.source_id,
        text: doc.text,
        pair_id: doc.pair_id,
        parent_id: doc.parent_id
      )
    end

    # Enqueue multiple documents for later embedding
    #
    # More efficient than calling enqueue() multiple times.
    # Resolves all external IDs to internal IDs in a single transaction.
    def enqueue_batch(docs : Array(Document))
      return if docs.empty?

      write_transaction do |cnn, _|
        docs.each do |doc|
          # Resolve external IDs to internal IDs
          internal_source_id = SourceRegistry.resolve(cnn, doc.source_type, doc.source_id)
          internal_pair_id = if pid = doc.pair_id
                               SourceRegistry.resolve(cnn, doc.source_type, pid)
                             else
                               nil
                             end
          internal_parent_id = if pid = doc.parent_id
                                 SourceRegistry.resolve(cnn, doc.source_type, pid)
                               else
                                 nil
                               end

          enqueue_internal(
            source_type: doc.source_type,
            internal_source_id: internal_source_id,
            text: doc.text,
            internal_pair_id: internal_pair_id,
            internal_parent_id: internal_parent_id,
            db: cnn
          )
        end
      end
    end

    # Process queued items
    #
    # Embeds pending items from the queue using the service's batch_size.
    # Returns number of items successfully processed.
    #
    # Failed items have their status set to the error code and can be retried
    # up to max_retries times.
    #
    # NOTE: Queue items are not atomically claimed. This is intentional -
    # single-worker processing is the expected use case since we're hitting
    # one API endpoint with batched requests. Parallel workers would hit
    # rate limits and add complexity without benefit.
    def process_queue : Int32
      q = @db.memo_queries
      max_retries = @queue_config.max_retries
      processed = 0

      loop do
        raw_items = q.get_pending_queue(@batch_size)
        break if raw_items.empty?

        items = raw_items.map do |id, internal_source_id, stored_text|
          source_type, text, pair_id, parent_id = parse_queue_text_internal(stored_text)
          {id, internal_source_id, source_type, text, pair_id, parent_id}
        end

        items.each do |id, internal_source_id, source_type, text, pair_id, parent_id|
          begin
            stored = embed_and_store_internal(
              source_type: source_type,
              internal_source_id: internal_source_id,
              text: text,
              internal_pair_id: pair_id,
              internal_parent_id: parent_id
            )
            q.mark_queue_success(id, Time.utc.to_unix_ms)
            processed += stored
          rescue ex
            attempts = q.get_queue_attempts(id)
            new_attempts = attempts + 1

            if new_attempts >= max_retries
              q.mark_queue_failed(id, ex.message, new_attempts, Time.utc.to_unix_ms)
            else
              q.mark_queue_retry(id, new_attempts, ex.message)
            end
          end
        end
      end

      processed
    end

    # Process queued items asynchronously
    #
    # Spawns a fiber to process the queue and returns immediately.
    # Use queue_stats to check progress.
    def process_queue_async
      spawn do
        process_queue
      end
    end

    # Process a specific queued item by internal source ID
    #
    # Used by index() for immediate processing with retry support.
    # Returns number of chunks stored.
    private def process_queue_item_internal(internal_source_id : Int64) : Int32
      q = @db.memo_queries
      max_retries = @queue_config.max_retries

      row = q.get_queue_item(internal_source_id)
      return 0 unless row

      id, stored_text = row
      source_type, text, pair_id, parent_id = parse_queue_text_internal(stored_text)

      attempts = 0
      last_error : Exception? = nil

      while attempts < max_retries
        begin
          chunks_stored = embed_and_store_internal(
            source_type: source_type,
            internal_source_id: internal_source_id,
            text: text,
            internal_pair_id: pair_id,
            internal_parent_id: parent_id
          )
          q.mark_queue_item_success(id, Time.utc.to_unix_ms, attempts + 1)
          return chunks_stored
        rescue ex
          last_error = ex
          attempts += 1
          q.mark_queue_retry(id, attempts, ex.message)
        end
      end

      q.mark_queue_failed(id, last_error.try(&.message), attempts, Time.utc.to_unix_ms)
      raise Exception.new("Index failed after #{max_retries} attempts: #{last_error.try(&.message)}")
    end

    # Get queue statistics
    #
    # Returns counts of pending and failed items.
    def queue_stats : QueueStats
      pending, failed = @db.memo_queries.queue_stats
      QueueStats.new(pending, failed)
    end

    # Clear completed items from the queue
    #
    # Removes successfully processed items (status = 0).
    # Returns number of items removed.
    def clear_completed_queue : Int32
      @db.memo_queries.clear_completed_queue
    end

    # Clear all items from the queue
    #
    # Removes all items regardless of status.
    # Returns number of items removed.
    def clear_queue : Int32
      @db.memo_queries.clear_queue
    end

    # Re-index all content of a given source type
    #
    # Deletes existing embeddings and queues text for re-embedding.
    # Requires text storage to be enabled.
    #
    # Returns number of items queued for re-indexing.
    def reindex(source_type : String) : Int32
      raise "Text storage required for reindex without block" unless @text_storage

      queued = 0

      # Get source texts and metadata from chunks table
      # texts stores full content (keyed by internal source_id), chunks has metadata
      # Join through sources to get only sources of the requested type
      sources = @db.memo_queries.get_texts_for_reindex(source_type)

      return 0 if sources.empty?

      write_transaction do |cnn, pending|
        # Delete existing chunks and embeddings for this source type
        # (orphan cleanup will handle embeddings not referenced elsewhere)
        sources.each do |internal_source_id, _, _, _|
          delete_internal(cnn, pending, internal_source_id, source_type)
        end

        # Queue for re-embedding using internal IDs
        sources.each do |internal_source_id, pair_id, parent_id, text|
          enqueue_internal(
            source_type: source_type,
            internal_source_id: internal_source_id,
            text: text,
            internal_pair_id: pair_id,
            internal_parent_id: parent_id,
            db: cnn
          )
          queued += 1
        end
      end

      queued
    end

    # Re-index all content of a given source type using a block to fetch text
    #
    # Use this when text storage is disabled. The block receives the external
    # source_id and should return the text to embed.
    #
    # Returns number of items queued for re-indexing.
    #
    # Example:
    # ```
    # memo.reindex("article") do |source_id|
    #   app.get_article_text(source_id)
    # end
    # memo.process_queue
    # ```
    def reindex(source_type : String, &block : ExternalId -> String) : Int32
      queued = 0

      # Get all internal source_ids and metadata for this source type
      # plus external IDs for the callback
      sources = [] of {Int64, ExternalId, Int64?, Int64?}

      @db.memo_queries.get_chunks_for_reindex(source_type, @service_id).each do |internal_source_id, external_int, external_text, pair_id, parent_id|
        external_id : ExternalId = external_int || external_text.not_nil!
        sources << {internal_source_id, external_id, pair_id, parent_id}
      end

      return 0 if sources.empty?

      write_transaction do |cnn, pending|
        # Delete existing chunks and embeddings
        sources.each do |internal_source_id, _, _, _|
          delete_internal(cnn, pending, internal_source_id, source_type)
        end

        # Queue for re-embedding using block to get text (passes external ID)
        sources.each do |internal_source_id, external_id, pair_id, parent_id|
          text = block.call(external_id)
          enqueue_internal(
            source_type: source_type,
            internal_source_id: internal_source_id,
            text: text,
            internal_pair_id: pair_id,
            internal_parent_id: parent_id,
            db: cnn
          )
          queued += 1
        end
      end

      queued
    end

    # =========================================================================
    # Vocabulary Operations
    # =========================================================================

    # Build vocabulary from indexed content
    #
    # Extracts unique words from all stored texts, embeds them in batches,
    # and stores in the vocab table for word-level similarity search.
    #
    # Requires text storage to be enabled.
    #
    # Options:
    # - batch_size: Number of words to embed per API call (default 2000)
    # - clear_existing: Whether to clear existing vocab first (default true)
    #
    # Returns number of words stored
    #
    # Example:
    # ```
    # memo.build_vocab
    # results = memo.like("database")
    # ```
    def build_vocab(batch_size : Int32 = 2000, clear_existing : Bool = true) : Int32
      raise "Text storage required for build_vocab" unless @text_storage

      texts = @db.memo_queries.get_all_texts

      return 0 if texts.empty?

      # Extract terms with frequencies
      terms = Vocab.extract_terms_batch(texts)
      return 0 if terms.empty?

      # Clear existing vocab if requested
      Vocab.clear(@db, @service_id) if clear_existing

      # Embed and store in batches
      stored = 0
      terms.each_slice(batch_size) do |batch|
        words = batch.map(&.word)
        frequencies = batch.map(&.count)

        # Embed the batch
        result = @provider.embed_texts(words, "document")

        # Store embeddings
        Vocab.store_batch(@db, words, result.embeddings, frequencies, @service_id)
        stored += words.size
      end

      stored
    end

    # Find words semantically similar to the query
    #
    # Searches the vocabulary table for words with similar embeddings.
    # Requires vocabulary to be built first with build_vocab().
    #
    # Returns array of VocabResult with word, score, and frequency.
    #
    # Example:
    # ```
    # results = memo.like("database")
    # results.each do |r|
    #   puts "#{r.word}: #{r.score}"
    # end
    # ```
    def like(
      query : String,
      limit : Int32 = 10,
      min_score : Float64 = 0.5,
    ) : Array(Vocab::Result)
      # Generate query embedding
      query_embedding, _tokens = @provider.embed_text(query, "query")

      # Search vocab
      Vocab.search(@db, query_embedding, @service_id, limit, min_score)
    end

    # Get vocabulary statistics
    def vocab_stats : Int64
      Vocab.count(@db, @service_id)
    end

    # Clear vocabulary for current service
    def clear_vocab
      Vocab.clear(@db, @service_id)
    end

    # =========================================================================
    # File Indexing Operations
    # =========================================================================

    # Index files from a directory
    #
    # Walks directory, respects ignore files, skips binary files,
    # and indexes text content. Tracks file metadata for incremental updates.
    #
    # Options:
    # - root: Directory to index
    # - ignore_file: Ignore file name (default ".gitignore")
    # - incremental: Skip unchanged files based on mtime (default true)
    # - dry_run: List files without indexing (default false)
    #
    # Returns tuple of (indexed_count, skipped_count, total_files)
    #
    # Example:
    # ```
    # indexed, skipped, total = memo.index_files("/path/to/project")
    # ```
    def index_files(
      root : String,
      ignore_file : String = ".gitignore",
      incremental : Bool = true,
      dry_run : Bool = false,
      &block : String, Symbol ->
    ) : {Int32, Int32, Int32}
      root_path = Path.new(root).expand.to_s
      indexed = 0
      skipped = 0
      total = 0

      # Collect files to index
      files_to_index = [] of {Int64, String, Files::FileInfo} # source_id, content, info

      Files.walk(root_path, ignore_file) do |file_path|
        total += 1
        info = Files.file_info(file_path, root_path)

        # Check if already indexed
        existing = Files.get_by_path(@db, info.path)

        if existing && incremental && !Files.needs_update?(existing, info.mtime)
          skipped += 1
          block.call(info.path, :skipped)
          next
        end

        if dry_run
          block.call(info.path, :would_index)
          next
        end

        # Read file content
        content = File.read(file_path)

        # Get or create source (memo-managed, no external_id)
        source_id = if existing
                      existing.source_id
                    else
                      SourceRegistry.create(@db, "file")
                    end

        files_to_index << {source_id, content, info}
        block.call(info.path, :indexed)
      end

      # Batch process all files
      return {0, skipped, total} if files_to_index.empty?

      index_files_batched(files_to_index)
      indexed = files_to_index.size

      {indexed, skipped, total}
    end

    # Batch index multiple files with a single API call
    #
    # Much more efficient than indexing files one at a time.
    private def index_files_batched(files : Array({Int64, String, Files::FileInfo}))
      return if files.empty?

      # Phase 1: Chunk all files and collect data
      all_chunks = [] of {Int64, String, Int32, Int32} # source_id, chunk_text, offset, size
      vocab_map = Hash(String, Int32).new(0)           # word => total count

      files.each do |source_id, content, info|
        chunks = Chunking.chunk_text(content, @chunking_config)
        chunks.each do |(chunk_text, offset, size)|
          all_chunks << {source_id, chunk_text, offset, size}
        end

        # Extract vocabulary
        if @build_vocab
          word_freqs = Vocab.extract_terms(content)
          word_freqs.each do |wf|
            vocab_map[wf.word] += wf.count
          end
        end
      end

      # Check which vocab words already exist
      new_vocab = [] of Vocab::WordFrequency
      existing_vocab = [] of Vocab::WordFrequency

      if @build_vocab && !vocab_map.empty?
        all_words = vocab_map.keys
        existing_words = Vocab.get_existing_words(@db, all_words, @service_id)

        vocab_map.each do |word, count|
          wf = Vocab::WordFrequency.new(word, count)
          if existing_words.includes?(word)
            existing_vocab << wf
          else
            new_vocab << wf
          end
        end
      end

      # Phase 2: Single batched API call for all chunks + new vocab
      chunk_texts = all_chunks.map { |(_, chunk_text, _, _)| chunk_text }
      new_words = new_vocab.map(&.word)
      texts_to_embed = chunk_texts + new_words

      return if texts_to_embed.empty?

      embed_result = embed_texts_batched(texts_to_embed)

      # Phase 3: Store everything in a transaction
      write_transaction do |cnn, pending|
        # Delete existing chunks for all sources being re-indexed
        source_ids = files.map { |(source_id, _, _)| source_id }.uniq
        source_ids.each do |source_id|
          delete_internal(cnn, pending, source_id, "file")
        end

        # Store source texts
        if @text_storage
          files.each do |source_id, content, info|
            store_source_text_internal(source_id, content, info.content_hash, db: cnn)
          end
        end

        # Store file metadata
        files.each do |source_id, _, info|
          Files.store(cnn, source_id, info)
        end

        # Store chunk embeddings
        all_chunks.each_with_index do |(source_id, chunk_text, offset, size), idx|
          hash = Storage.compute_hash(chunk_text)
          embedding = embed_result.embeddings[idx]
          token_count = embed_result.token_counts[idx]

          inserted, rowid = Storage.store_embedding(cnn, hash, token_count, @service_id)
          IndexJournal.record_vector(cnn, pending, rowid, @service_id, embedding, inserted)

          Storage.create_chunk(
            db: cnn,
            hash: hash,
            source_type: "file",
            source_id: source_id,
            offset: offset,
            size: size
          )
        end

        # Store new vocab embeddings
        if @build_vocab
          chunk_count = all_chunks.size
          new_vocab.each_with_index do |wf, idx|
            embedding = embed_result.embeddings[chunk_count + idx]
            Vocab.store_word(cnn, wf.word, embedding, wf.count, @service_id)
          end

          # Update frequencies for existing words
          Vocab.update_frequencies(cnn, existing_vocab, @service_id)
        end
      end
    end

    # Index files without progress callback
    def index_files(
      root : String,
      ignore_file : String = ".gitignore",
      incremental : Bool = true,
      dry_run : Bool = false,
    ) : {Int32, Int32, Int32}
      index_files(root, ignore_file, incremental, dry_run) { |_, _| }
    end

    # Index an explicit list of file paths
    #
    # Unlike index_files, this does not walk directories or use ignore files.
    # Relative paths are resolved from `root` (defaults to Dir.current).
    # Binary files are still skipped.
    #
    # Returns tuple of (indexed_count, skipped_count, total_files)
    def index_file_list(
      paths : Array(String),
      root : String = Dir.current,
      incremental : Bool = true,
      dry_run : Bool = false,
      &block : String, Symbol ->
    ) : {Int32, Int32, Int32}
      root_path = Path.new(root).expand.to_s
      indexed = 0
      skipped = 0
      total = 0

      files_to_index = [] of {Int64, String, Files::FileInfo}

      paths.each do |file_path|
        expanded = Path.new(file_path).expand.to_s

        # Skip binary files
        if Files.binary?(expanded)
          block.call(file_path, :skipped)
          skipped += 1
          total += 1
          next
        end

        total += 1
        info = Files.file_info(expanded, root_path)

        existing = Files.get_by_path(@db, info.path)

        if existing && incremental && !Files.needs_update?(existing, info.mtime)
          skipped += 1
          block.call(info.path, :skipped)
          next
        end

        if dry_run
          block.call(info.path, :would_index)
          next
        end

        content = File.read(expanded)

        source_id = if existing
                      existing.source_id
                    else
                      SourceRegistry.create(@db, "file")
                    end

        files_to_index << {source_id, content, info}
        block.call(info.path, :indexed)
      end

      return {0, skipped, total} if files_to_index.empty?

      index_files_batched(files_to_index)
      indexed = files_to_index.size

      {indexed, skipped, total}
    end

    # Index file list without progress callback
    def index_file_list(
      paths : Array(String),
      root : String = Dir.current,
      incremental : Bool = true,
      dry_run : Bool = false,
    ) : {Int32, Int32, Int32}
      index_file_list(paths, root, incremental, dry_run) { |_, _| }
    end

    # Get file record by path
    def get_file(path : String) : Files::FileRecord?
      Files.get_by_path(@db, path)
    end

    # Get file record by content hash
    def get_file_by_hash(hash : Bytes) : Files::FileRecord?
      Files.get_by_hash(@db, hash)
    end

    # Get file record by source ID
    def get_file_by_source(source_id : Int64) : Files::FileRecord?
      Files.get_by_source(@db, source_id)
    end

    # List indexed files
    def list_files(limit : Int32 = 100, offset : Int32 = 0) : Array(Files::FileRecord)
      Files.list(@db, limit, offset)
    end

    # Count indexed files
    def file_count : Int64
      Files.count(@db)
    end

    # Initialize provider from service name, format parameters, or default
    #
    # Priority:
    # 1. If service name is provided, looks up the configuration from the database
    # 2. If format is provided, creates inline configuration
    # 3. Otherwise, uses the default service
    #
    # Returns ProviderConfig with provider instance and service metadata
    private def init_provider(
      service : String?,
      format : String?,
      base_url : String?,
      model : String?,
      dimensions : Int32?,
      max_tokens : Int32?,
      api_key : String?,
      chunking_max_tokens : Int32,
    ) : ProviderConfig
      if service
        # Look up existing service configuration by name
        svc = Storage.get_service_by_name(@db, service)
        raise ArgumentError.new("Service '#{service}' not found") unless svc

        svc_id, svc_format, svc_base_url, svc_model, svc_dimensions, svc_max_tokens, svc_tokens_per_byte = svc

        # Create provider instance from stored config
        provider_instance = Providers::Registry.create(svc_format, api_key, svc_model, svc_base_url)
        raise ArgumentError.new("Unknown format: #{svc_format}") unless provider_instance

        # Validate chunking doesn't exceed provider limits
        if chunking_max_tokens > svc_max_tokens
          raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds service limit (#{svc_max_tokens})")
        end

        ProviderConfig.new(provider_instance, svc_id, service, svc_format, svc_model, svc_dimensions, svc_max_tokens, svc_tokens_per_byte)
      elsif format
        # Configure inline from format parameters
        final_format = format

        # Try to find existing service by format/model
        if model
          existing = Storage.get_service_by_format_model(@db, final_format, model)
        end

        if existing
          # Use existing service configuration
          # Don't allow overriding dimensions - it's intrinsic to the model
          # and overriding would cause USearch index dimension mismatch
          _id, _fmt, _base_url, svc_model, svc_dimensions, svc_max_tokens, svc_tokens_per_byte = existing
          if dimensions && dimensions != svc_dimensions
            raise ArgumentError.new("Cannot override dimensions (#{dimensions}) for existing service with dimensions=#{svc_dimensions}")
          end
          final_model = svc_model
          final_dimensions = svc_dimensions
          # max_tokens can be overridden - it's a limit we choose, not intrinsic to model
          final_max_tokens = max_tokens || svc_max_tokens
          final_tokens_per_byte = svc_tokens_per_byte
        else
          # No existing service - require all parameters
          raise ArgumentError.new("model required for format: #{final_format}") unless model
          raise ArgumentError.new("dimensions required for #{final_format}/#{model}") unless dimensions
          raise ArgumentError.new("max_tokens required for #{final_format}/#{model}") unless max_tokens
          final_model = model
          final_dimensions = dimensions
          final_max_tokens = max_tokens
          final_tokens_per_byte = 0.25
        end

        # Validate chunking doesn't exceed provider limits
        if chunking_max_tokens > final_max_tokens
          raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds provider limit (#{final_max_tokens})")
        end

        # Create provider instance
        provider_instance = Providers::Registry.create(final_format, api_key, final_model, base_url)
        raise ArgumentError.new("Unknown format: #{final_format}") unless provider_instance

        # Register or get existing service in database (auto-generates name)
        service_id = Storage.register_service(
          db: @db,
          name: nil, # Auto-generate from format/model
          format: final_format,
          base_url: base_url,
          model: final_model,
          dimensions: final_dimensions,
          max_tokens: final_max_tokens
        )

        ProviderConfig.new(provider_instance, service_id, "#{final_format}/#{final_model}", final_format, final_model, final_dimensions, final_max_tokens, final_tokens_per_byte)
      else
        # Use the default service
        default_svc = ServiceProvider.get_default(@db)
        raise ArgumentError.new("No default service configured") unless default_svc

        # Create provider instance from default service config
        provider_instance = Providers::Registry.create(default_svc.format, api_key, default_svc.model, default_svc.base_url)
        raise ArgumentError.new("Unknown format: #{default_svc.format}") unless provider_instance

        # Validate chunking doesn't exceed provider limits
        if chunking_max_tokens > default_svc.max_tokens
          raise ArgumentError.new("chunking_max_tokens (#{chunking_max_tokens}) exceeds service limit (#{default_svc.max_tokens})")
        end

        ProviderConfig.new(provider_instance, default_svc.id, default_svc.name, default_svc.format, default_svc.model, default_svc.dimensions, default_svc.max_tokens, default_svc.tokens_per_byte)
      end
    end

    # Store source text (keyed by internal source_id)
    # Also populates FTS5 index for full-text search
    #
    # Stores the original un-chunked text. Chunk text is extracted
    # using offset/size from the chunks table.
    private def store_source_text_internal(internal_source_id : Int64, content : String, content_hash : Bytes? = nil, skip_hash : Bool = false, db : DBHandle = @db)
      hash = skip_hash ? nil : (content_hash || Storage.compute_hash(content))
      db.memo_queries.upsert_text(internal_source_id, content, hash, Time.utc.to_unix_ms)
      db.memo_dialect.fts_upsert(db, internal_source_id, content)
    end

    # Embed texts in batches of @batch_size to avoid API input limits
    private def embed_texts_batched(texts : Array(String), input_type : String? = "document") : Providers::EmbedResult
      return @provider.embed_texts(texts, input_type) if texts.size <= @batch_size

      all_embeddings = [] of Array(Float64)
      all_token_counts = [] of Int32
      total_tokens = 0

      texts.each_slice(@batch_size) do |batch|
        result = @provider.embed_texts(batch, input_type)
        all_embeddings.concat(result.embeddings)
        all_token_counts.concat(result.token_counts)
        total_tokens += result.total_tokens
      end

      Providers::EmbedResult.new(all_embeddings, all_token_counts, total_tokens)
    end

    # Check if source text has changed by comparing content hash
    private def source_text_changed?(internal_source_id : Int64, content_hash : Bytes) : Bool
      stored_hash = @db.memo_queries.get_text_hash(internal_source_id)
      stored_hash.nil? || stored_hash != content_hash
    end

    # Delete source text by internal ID
    private def delete_source_text_internal(internal_source_id : Int64, db : DBHandle = @db)
      db.memo_queries.delete_text(internal_source_id)
      db.memo_dialect.fts_delete(db, internal_source_id)
    end

    # Get source text by internal source_id
    def get_source_text(internal_source_id : Int64) : String?
      get_source_text_internal(internal_source_id)
    end

    # Get source text by internal source_id (internal)
    private def get_source_text_internal(internal_source_id : Int64) : String?
      @db.memo_queries.get_text(internal_source_id)
    end

    # Parse queue text to extract metadata and actual text (internal format)
    #
    # Format: "MEMO_META:source_type,pair_id,parent_id\n" followed by actual text
    # Returns {source_type, text, internal_pair_id, internal_parent_id}
    private def parse_queue_text_internal(stored_text : String) : {String, String, Int64?, Int64?}
      if stored_text.starts_with?("MEMO_META:")
        newline_idx = stored_text.index('\n')
        if newline_idx
          meta_line = stored_text[10...newline_idx]
          text = stored_text[(newline_idx + 1)..]

          parts = meta_line.split(',', 3)
          source_type = parts[0]
          pair_id = parts.size > 1 && !parts[1].empty? ? parts[1].to_i64 : nil
          parent_id = parts.size > 2 && !parts[2].empty? ? parts[2].to_i64 : nil

          {source_type, text, pair_id, parent_id}
        else
          # Malformed - no newline
          {"unknown", stored_text, nil, nil}
        end
      else
        # No metadata prefix - legacy format, shouldn't happen with new code
        {"unknown", stored_text, nil, nil}
      end
    end

    # Core embedding logic - chunks, embeds, and stores a document
    #
    # This is the internal implementation used by both process_queue and
    # process_queue_item. It does not interact with the queue table.
    #
    # All IDs are internal (FK to sources table).
    #
    # Deletes existing chunks for the source before re-indexing to ensure
    # clean state if chunking settings have changed.
    #
    # Returns number of chunks successfully stored, or -1 if skipped (unchanged).
    private def embed_and_store_internal(
      source_type : String,
      internal_source_id : Int64,
      text : String,
      internal_pair_id : Int64? = nil,
      internal_parent_id : Int64? = nil,
    ) : Int32
      # Check if content has changed (skip re-embedding if identical)
      content_hash = Storage.compute_hash(text)
      unless source_text_changed?(internal_source_id, content_hash)
        return -1 # Unchanged, skip
      end

      # Chunk text (returns tuples of {text, offset, size})
      chunks = Chunking.chunk_text(text, @chunking_config)
      return 0 if chunks.empty?

      # Extract just the text for embedding
      chunk_texts = chunks.map { |(chunk_text, _, _)| chunk_text }

      # Extract vocabulary if enabled
      new_word_freqs = [] of Vocab::WordFrequency
      existing_word_freqs = [] of Vocab::WordFrequency

      if @build_vocab
        word_freqs = Vocab.extract_terms(text)
        if !word_freqs.empty?
          all_words = word_freqs.map(&.word)
          existing_words = Vocab.get_existing_words(@db, all_words, @service_id)

          new_word_freqs = word_freqs.reject { |wf| existing_words.includes?(wf.word) }
          existing_word_freqs = word_freqs.select { |wf| existing_words.includes?(wf.word) }
        end
      end

      # Combine chunks + new words for embedding in single API call
      new_words = new_word_freqs.map(&.word)
      texts_to_embed = chunk_texts + new_words

      # Embed all texts (API call - outside transaction so failure is safe)
      embed_result = embed_texts_batched(texts_to_embed)

      # Update tokens_per_byte ratio based on actual API results (chunks only)
      total_bytes = chunk_texts.sum(&.bytesize)
      if total_bytes > 0 && embed_result.total_tokens > 0
        observed_ratio = embed_result.total_tokens.to_f / total_bytes
        Storage.update_tokens_per_byte(@db, @service_id, observed_ratio)

        # Also update in-memory config so future chunking uses the new ratio
        # (Storage.update_tokens_per_byte uses EMA, so fetch the actual updated value)
        updated_ratio = @db.memo_queries.get_service_tokens_per_byte(@service_id)
        @chunking_config = @chunking_config.with_tokens_per_byte(updated_ratio) if updated_ratio
      end

      # Delete old and store new atomically
      success_count = 0

      write_transaction do |cnn, pending|
        # Delete existing chunks for this source before storing new ones
        # This ensures clean state if chunking settings have changed
        delete_internal(cnn, pending, internal_source_id, source_type)

        # Store source text once (not per-chunk)
        # Chunk text is extracted using offset/size when needed
        store_source_text_internal(internal_source_id, text, content_hash, db: cnn) if @text_storage

        # Store chunk embeddings
        chunks.each_with_index do |(chunk_text, offset, size), idx|
          hash = Storage.compute_hash(chunk_text)
          embedding = embed_result.embeddings[idx]
          token_count = embed_result.token_counts[idx]

          # Store embedding (deduplicated by hash) and add to USearch index
          inserted, rowid = Storage.store_embedding(cnn, hash, token_count, @service_id)
          IndexJournal.record_vector(cnn, pending, rowid, @service_id, embedding, inserted)

          # Create chunk reference with offset/size from chunking
          # All IDs are internal (FK to sources table)
          chunk_id = Storage.create_chunk(
            db: cnn,
            hash: hash,
            source_type: source_type,
            source_id: internal_source_id,
            offset: offset,
            size: size,
            pair_id: internal_pair_id,
            parent_id: internal_parent_id
          )

          # Only count if chunk was actually inserted (not ignored as duplicate)
          success_count += 1 if chunk_id > 0
        end

        # Store new word embeddings (embeddings start after chunks)
        if @build_vocab
          chunk_count = chunks.size
          new_word_freqs.each_with_index do |wf, idx|
            embedding = embed_result.embeddings[chunk_count + idx]
            Vocab.store_word(cnn, wf.word, embedding, wf.count, @service_id)
          end

          # Update frequencies for existing words
          Vocab.update_frequencies(cnn, existing_word_freqs, @service_id)
        end
      end

      success_count
    end
  end
end
