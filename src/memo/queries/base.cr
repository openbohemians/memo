module Memo
  # Abstract query interface for database-backend-specific SQL.
  #
  # Each backend (SQLite, PostgreSQL) implements all query methods
  # with SQL native to that backend. This avoids placeholder
  # translation and keeps SQL explicit per backend.
  abstract class Queries
    getter db : DBHandle

    def initialize(@db : DBHandle)
    end

    # Same queries, run on one connection (for use inside a transaction).
    abstract def for_connection(cnn : DB::Connection) : Queries

    # Factory for PostgreSQL queries (set by requiring memo/pg)
    @@pg_factory : (DB::Database -> Queries)? = nil

    def self.register_pg(&factory : DB::Database -> Queries)
      @@pg_factory = factory
    end

    def self.for(db : DB::Database, connection_string : String) : Queries
      if connection_string.starts_with?("postgres")
        factory = @@pg_factory
        if factory
          factory.call(db)
        else
          raise ArgumentError.new("PostgreSQL queries require: require \"memo/pg\"")
        end
      else
        SQLite.new(db)
      end
    end

    # =========================================================================
    # Services
    # =========================================================================

    abstract def find_service_id(name : String) : Int64?

    abstract def insert_service(
      name : String, format : String, base_url : String?,
      model : String, dimensions : Int32, max_tokens : Int32, created_at : Int64,
    ) : Int64

    abstract def get_service_by_name(name : String) : {Int64, String, String?, String, Int32, Int32, Float64}?

    abstract def get_service_by_format_model(format : String, model : String) : {Int64, String, String?, String, Int32, Int32, Float64}?

    abstract def get_tokens_per_byte(service_id : Int64) : Float64?

    abstract def update_tokens_per_byte(tokens_per_byte : Float64, service_id : Int64) : Nil

    abstract def get_service_info(id : Int64) : ServiceProvider::Info?

    abstract def get_service_info_by_name(name : String) : ServiceProvider::Info?

    abstract def get_default_service : ServiceProvider::Info?

    abstract def clear_default_service : Nil

    abstract def set_default_service(id : Int64) : Nil

    abstract def list_services : Array(ServiceProvider::Info)

    abstract def list_services_by_format(format : String) : Array(ServiceProvider::Info)

    abstract def update_service(id : Int64, updates : Array(String), params : Array(DB::Any)) : Int64

    abstract def get_embedding_hashes_for_service(service_id : Int64) : Array(Bytes)

    abstract def delete_chunks_by_hash(hash : Bytes) : Nil

    abstract def delete_embeddings_by_service(service_id : Int64) : Nil

    abstract def delete_service(id : Int64) : Nil

    abstract def count_embeddings_for_service(service_id : Int64) : Int64

    abstract def count_chunks_for_service(service_id : Int64) : Int64

    abstract def service_exists?(id : Int64) : Bool

    abstract def count_services : Int64

    # Insert service with is_default and return ID (for ServiceProvider.create)
    abstract def insert_service_full(
      name : String, format : String, base_url : String?,
      model : String, dimensions : Int32, max_tokens : Int32,
      is_default : Int32, created_at : Int64,
    ) : Int64

    # =========================================================================
    # Embeddings
    # =========================================================================

    abstract def insert_embedding_ignore(hash : Bytes, service_id : Int64, token_count : Int32, created_at : Int64) : Int64

    abstract def get_embedding_rowid(hash : Bytes, service_id : Int64) : Int64

    abstract def get_embedding_rowid?(hash : Bytes, service_id : Int64) : Int64?

    # =========================================================================
    # Chunks
    # =========================================================================

    abstract def insert_chunk_ignore(
      hash : Bytes, source_id : Int64, source_type : String,
      pair_id : Int64?, parent_id : Int64?,
      offset : Int32?, size : Int32, created_at : Int64,
    ) : Int64

    abstract def get_chunk_id(source_id : Int64, offset : Int32?) : Int64

    abstract def increment_match_count(chunk_ids : Array(Int64)) : Nil

    abstract def increment_read_count(chunk_ids : Array(Int64)) : Nil

    abstract def get_chunk_hashes(source_id : Int64, source_type : String?) : Array(Bytes)

    abstract def delete_chunks(hash : Bytes, source_id : Int64, source_type : String) : Int32

    abstract def delete_chunks(hash : Bytes, source_id : Int64) : Int32

    abstract def count_chunks_by_hash(hash : Bytes) : Int64

    abstract def delete_embeddings_by_hash(hash : Bytes) : Nil

    # =========================================================================
    # Sources
    # =========================================================================

    abstract def insert_source(source_type : String, created_at : Int64) : Int64

    abstract def insert_source_int(source_type : String, external_id : Int64, created_at : Int64) : Int64

    abstract def insert_source_text(source_type : String, external_id : String, created_at : Int64) : Int64

    abstract def insert_source_blob(source_type : String, external_id : Bytes, created_at : Int64) : Int64

    abstract def find_source_int(source_type : String, external_id : Int64) : Int64?

    abstract def find_source_text(source_type : String, external_id : String) : Int64?

    abstract def find_source_blob(source_type : String, external_id : Bytes) : Int64?

    abstract def find_source_int_any_type(external_id : Int64) : Int64?

    abstract def find_source_text_any_type(external_id : String) : Int64?

    abstract def find_source_blob_any_type(external_id : Bytes) : Int64?

    abstract def get_source_external(internal_id : Int64) : {String, Int64?, String?, Bytes?}?

    abstract def delete_source_int(source_type : String, external_id : Int64) : Int64

    abstract def delete_source_text(source_type : String, external_id : String) : Int64

    abstract def delete_source_blob(source_type : String, external_id : Bytes) : Int64

    abstract def delete_source_by_id(internal_id : Int64) : Int64

    abstract def list_sources(source_type : String, limit : Int32, offset : Int32) : Array({Int64, Int64?, String?, Bytes?})

    # =========================================================================
    # Files
    # =========================================================================

    abstract def upsert_file(source_id : Int64, path : String, content_hash : Bytes, mtime : Int64, size : Int64, created_at : Int64) : Nil

    abstract def get_file_by_path(path : String) : Files::FileRecord?

    abstract def get_file_by_hash(hash : Bytes) : Files::FileRecord?

    abstract def get_file_by_source(source_id : Int64) : Files::FileRecord?

    abstract def delete_file(source_id : Int64) : Int64

    abstract def list_files(limit : Int32, offset : Int32) : Array(Files::FileRecord)

    abstract def count_files : Int64

    # =========================================================================
    # Vocab
    # =========================================================================

    abstract def get_vocab(service_id : Int64, &block : DB::ResultSet ->) : Nil

    abstract def upsert_vocab(word : String, service_id : Int64, embedding : Bytes, frequency : Int32, created_at : Int64) : Nil

    abstract def get_existing_words(service_id : Int64, words : Array(String)) : Set(String)

    abstract def update_word_frequency(count : Int32, word : String, service_id : Int64) : Nil

    abstract def delete_vocab(service_id : Int64) : Nil

    abstract def count_vocab(service_id : Int64) : Int64

    # =========================================================================
    # Queue
    # =========================================================================

    abstract def enqueue(source_id : Int64, text : String, created_at : Int64) : Nil

    abstract def get_pending_queue(limit : Int32) : Array({Int64, Int64, String})

    abstract def mark_queue_success(id : Int64, processed_at : Int64) : Nil

    abstract def get_queue_attempts(id : Int64) : Int32

    abstract def mark_queue_failed(id : Int64, error_message : String?, attempts : Int32, processed_at : Int64) : Nil

    abstract def mark_queue_retry(id : Int64, attempts : Int32, error_message : String?) : Nil

    abstract def get_queue_item(source_id : Int64) : {Int64, String}?

    abstract def mark_queue_item_success(id : Int64, processed_at : Int64, attempts : Int32) : Nil

    abstract def queue_stats : {Int64, Int64}

    abstract def clear_completed_queue : Int32

    abstract def clear_queue : Int32

    # =========================================================================
    # Texts
    # =========================================================================

    abstract def upsert_text(source_id : Int64, content : String, content_hash : Bytes?, created_at : Int64) : Nil

    abstract def get_text_hash(source_id : Int64) : Bytes?

    abstract def delete_text(source_id : Int64) : Nil

    abstract def get_text(source_id : Int64) : String?

    abstract def get_all_texts : Array(String)

    abstract def get_service_tokens_per_byte(service_id : Int64) : Float64?

    # =========================================================================
    # Stats (Service-level)
    # =========================================================================

    abstract def count_service_embeddings(service_id : Int64) : Int64

    abstract def count_service_chunks(service_id : Int64) : Int64

    abstract def count_service_sources(service_id : Int64) : Int64

    # =========================================================================
    # Reindex
    # =========================================================================

    abstract def get_texts_for_reindex(source_type : String) : Array({Int64, Int64?, Int64?, String})

    abstract def get_chunks_for_reindex(source_type : String, service_id : Int64) : Array({Int64, Int64?, String?, Int64?, Int64?})

    # =========================================================================
    # Search
    # =========================================================================

    abstract def search_filtered_rowids(
      service_id : Int64,
      params : Array(DB::Any),
      where_clauses : Array(String),
      text_join : String,
      fts_join : String,
    ) : Set(UInt64)

    # Which of `candidate_ids` pass the filter clauses (looked up by id, so the
    # cost depends on the number of candidates, not the collection)
    abstract def filter_candidates(
      service_id : Int64,
      params : Array(DB::Any),
      where_clauses : Array(String),
      text_join : String,
      fts_join : String,
      candidate_ids : Array(Int64),
    ) : Set(UInt64)

    abstract def fetch_search_results(
      rowids : Array(Int64),
      service_id : Int64,
      include_text : Bool,
    ) : Array({UInt64, Int64, Bytes, String, Int64, Int64?, String?, Bytes?, Int64?, Int64?, String?, Bytes?, Int64?, Int64?, String?, Bytes?, Int32?, Int32, Int32, Int32, String?})

    # =========================================================================
    # Query Cache
    # =========================================================================

    abstract def get_query_cache(query : String, service_id : Int64) : {Bytes, Int32}?

    abstract def upsert_query_cache(query : String, service_id : Int64, embedding : Bytes, token_count : Int32, created_at : Int64) : Nil

    abstract def count_query_cache(service_id : Int64) : Int64

    abstract def prune_query_cache(service_id : Int64, count : Int64) : Nil

    abstract def clear_query_cache(service_id : Int64) : Nil

    abstract def get_recent_query_cache(service_id : Int64, limit : Int32) : Array({String, Bytes, Int32})

    # =========================================================================
    # Vectors and index journal
    # =========================================================================

    abstract def upsert_vector(embedding_id : Int64, service_id : Int64, vector : Bytes) : Nil

    abstract def get_vector(embedding_id : Int64) : Bytes?

    abstract def delete_vector(embedding_id : Int64) : Nil

    abstract def count_vectors(service_id : Int64) : Int64

    # Up to `limit` {embedding id, vector} pairs with ids above `after_id`, in id order
    abstract def vectors_after(service_id : Int64, after_id : Int64, limit : Int32) : Array({Int64, Bytes})

    # {embedding id, service id} for every service's embedding of a hash
    abstract def embedding_ids_for_hash(hash : Bytes) : Array({Int64, Int64})

    abstract def embedding_ids_without_vectors(service_id : Int64) : Array(Int64)

    abstract def log_index_change(service_id : Int64, embedding_id : Int64) : Nil

    # Distinct embedding ids logged after `seq`
    abstract def index_changes_since(service_id : Int64, seq : Int64) : Array(Int64)

    abstract def max_index_log_seq(service_id : Int64) : Int64

    abstract def prune_index_log(service_id : Int64, through : Int64) : Nil

    # {pruned_through, vectors_backfilled}
    abstract def get_index_state(service_id : Int64) : {Int64, Bool}?

    abstract def set_index_pruned_through(service_id : Int64, seq : Int64) : Nil

    abstract def set_vectors_backfilled(service_id : Int64) : Nil

    # Remove a service's vectors, journal entries and journal state
    abstract def delete_index_data(service_id : Int64) : Nil

    # =========================================================================
    # Clustering
    # =========================================================================

    abstract def load_embedding_rowids(
      service_id : Int64,
      source_type : String,
      external_ids : Array(Int64),
    ) : Array({Int64, Int64})
  end
end
