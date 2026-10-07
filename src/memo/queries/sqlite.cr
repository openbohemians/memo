module Memo
  class Queries::SQLite < Queries
    def for_connection(cnn : DB::Connection) : Queries
      SQLite.new(cnn)
    end

    # =========================================================================
    # Services
    # =========================================================================

    def find_service_id(name : String) : Int64?
      @db.query_one?("SELECT id FROM memo_services WHERE name = ?", name, as: Int64)
    end

    def insert_service(
      name : String, format : String, base_url : String?,
      model : String, dimensions : Int32, max_tokens : Int32, created_at : Int64,
    ) : Int64
      @db.exec(
        "INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)",
        name, format, base_url, model, dimensions, max_tokens, created_at
      ).last_insert_id
    end

    def get_service_by_name(name : String) : {Int64, String, String?, String, Int32, Int32, Float64}?
      @db.query_one?(
        "SELECT id, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25)
         FROM memo_services WHERE name = ?", name
      ) do |rs|
        {rs.read(Int64), rs.read(String), rs.read(String?), rs.read(String), rs.read(Int32), rs.read(Int32), rs.read(Float64)}
      end
    end

    def get_service_by_format_model(format : String, model : String) : {Int64, String, String?, String, Int32, Int32, Float64}?
      @db.query_one?(
        "SELECT id, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25)
         FROM memo_services WHERE format = ? AND model = ?", format, model
      ) do |rs|
        {rs.read(Int64), rs.read(String), rs.read(String?), rs.read(String), rs.read(Int32), rs.read(Int32), rs.read(Float64)}
      end
    end

    def get_tokens_per_byte(service_id : Int64) : Float64?
      @db.query_one?("SELECT COALESCE(tokens_per_byte, 0.25) FROM memo_services WHERE id = ?", service_id, as: Float64)
    end

    def update_tokens_per_byte(tokens_per_byte : Float64, service_id : Int64) : Nil
      @db.exec("UPDATE memo_services SET tokens_per_byte = ? WHERE id = ?", tokens_per_byte, service_id)
    end

    def get_service_info(id : Int64) : ServiceProvider::Info?
      @db.query_one?(
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25), is_default, created_at
         FROM memo_services WHERE id = ?", id
      ) { |rs| read_service_info(rs) }
    end

    def get_service_info_by_name(name : String) : ServiceProvider::Info?
      @db.query_one?(
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25), is_default, created_at
         FROM memo_services WHERE name = ?", name
      ) { |rs| read_service_info(rs) }
    end

    def get_default_service : ServiceProvider::Info?
      @db.query_one?(
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25), is_default, created_at
         FROM memo_services WHERE is_default = 1 LIMIT 1"
      ) { |rs| read_service_info(rs) }
    end

    def clear_default_service : Nil
      @db.exec("UPDATE memo_services SET is_default = 0 WHERE is_default = 1")
    end

    def set_default_service(id : Int64) : Nil
      @db.exec("UPDATE memo_services SET is_default = 1 WHERE id = ?", id)
    end

    def list_services : Array(ServiceProvider::Info)
      services = [] of ServiceProvider::Info
      @db.query(
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25), is_default, created_at
         FROM memo_services ORDER BY created_at DESC"
      ) { |rs| rs.each { services << read_service_info(rs) } }
      services
    end

    def list_services_by_format(format : String) : Array(ServiceProvider::Info)
      services = [] of ServiceProvider::Info
      @db.query(
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25), is_default, created_at
         FROM memo_services WHERE format = ? ORDER BY created_at DESC", format
      ) { |rs| rs.each { services << read_service_info(rs) } }
      services
    end

    def update_service(id : Int64, updates : Array(String), params : Array(DB::Any)) : Int64
      @db.exec("UPDATE memo_services SET #{updates.join(", ")} WHERE id = ?", args: params + [id.as(DB::Any)])
      @db.exec("SELECT 1").rows_affected # dummy to get result
      id
    end

    def get_embedding_hashes_for_service(service_id : Int64) : Array(Bytes)
      hashes = [] of Bytes
      @db.query("SELECT hash FROM memo_embeddings WHERE service_id = ?", service_id) do |rs|
        rs.each { hashes << rs.read(Bytes) }
      end
      hashes
    end

    def delete_chunks_by_hash(hash : Bytes) : Nil
      @db.exec("DELETE FROM memo_chunks WHERE hash = ?", hash)
    end

    def delete_embeddings_by_service(service_id : Int64) : Nil
      @db.exec("DELETE FROM memo_embeddings WHERE service_id = ?", service_id)
    end

    def delete_service(id : Int64) : Nil
      @db.exec("DELETE FROM memo_services WHERE id = ?", id)
    end

    def count_embeddings_for_service(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_embeddings WHERE service_id = ?", service_id).as(Int64)
    end

    def count_chunks_for_service(service_id : Int64) : Int64
      @db.scalar(
        "SELECT COUNT(*) FROM memo_chunks c JOIN memo_embeddings e ON c.hash = e.hash WHERE e.service_id = ?",
        service_id
      ).as(Int64)
    end

    def service_exists?(id : Int64) : Bool
      @db.scalar("SELECT COUNT(*) FROM memo_services WHERE id = ?", id).as(Int64) > 0
    end

    def count_services : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_services").as(Int64)
    end

    def insert_service_full(
      name : String, format : String, base_url : String?,
      model : String, dimensions : Int32, max_tokens : Int32,
      is_default : Int32, created_at : Int64,
    ) : Int64
      @db.exec(
        "INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        name, format, base_url, model, dimensions, max_tokens, is_default, created_at
      ).last_insert_id
    end

    # =========================================================================
    # Embeddings
    # =========================================================================

    def insert_embedding_ignore(hash : Bytes, service_id : Int64, token_count : Int32, created_at : Int64) : Int64
      @db.exec(
        "INSERT OR IGNORE INTO memo_embeddings (hash, service_id, token_count, created_at) VALUES (?, ?, ?, ?)",
        hash, service_id, token_count, created_at
      )
      @db.query_one("SELECT rowid FROM memo_embeddings WHERE hash = ? AND service_id = ?", hash, service_id, as: Int64)
    end

    def get_embedding_rowid(hash : Bytes, service_id : Int64) : Int64
      @db.query_one("SELECT rowid FROM memo_embeddings WHERE hash = ? AND service_id = ?", hash, service_id, as: Int64)
    end

    def get_embedding_rowid?(hash : Bytes, service_id : Int64) : Int64?
      @db.query_one?("SELECT rowid FROM memo_embeddings WHERE hash = ? AND service_id = ?", hash, service_id, as: Int64)
    end

    # =========================================================================
    # Chunks
    # =========================================================================

    def insert_chunk_ignore(
      hash : Bytes, source_id : Int64, source_type : String,
      pair_id : Int64?, parent_id : Int64?,
      offset : Int32?, size : Int32, created_at : Int64,
    ) : Int64
      result = @db.exec(
        "INSERT OR IGNORE INTO memo_chunks (hash, source_id, source_type, pair_id, parent_id, offset, size, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        hash, source_id, source_type, pair_id, parent_id, offset, size, created_at
      )
      return 0_i64 if result.rows_affected == 0
      @db.query_one("SELECT id FROM memo_chunks WHERE source_id = ? AND offset IS ?", source_id, offset, as: Int64)
    end

    def get_chunk_id(source_id : Int64, offset : Int32?) : Int64
      @db.query_one("SELECT id FROM memo_chunks WHERE source_id = ? AND offset IS ?", source_id, offset, as: Int64)
    end

    def increment_match_count(chunk_ids : Array(Int64)) : Nil
      return if chunk_ids.empty?
      placeholders = chunk_ids.map { "?" }.join(", ")
      @db.exec("UPDATE memo_chunks SET match_count = match_count + 1 WHERE id IN (#{placeholders})", args: chunk_ids)
    end

    def increment_read_count(chunk_ids : Array(Int64)) : Nil
      return if chunk_ids.empty?
      placeholders = chunk_ids.map { "?" }.join(", ")
      @db.exec("UPDATE memo_chunks SET read_count = read_count + 1 WHERE id IN (#{placeholders})", args: chunk_ids)
    end

    def get_chunk_hashes(source_id : Int64, source_type : String?) : Array(Bytes)
      hashes = [] of Bytes
      if source_type
        @db.query("SELECT DISTINCT hash FROM memo_chunks WHERE source_id = ? AND source_type = ?", source_id, source_type) do |rs|
          rs.each { hashes << rs.read(Bytes) }
        end
      else
        @db.query("SELECT DISTINCT hash FROM memo_chunks WHERE source_id = ?", source_id) do |rs|
          rs.each { hashes << rs.read(Bytes) }
        end
      end
      hashes
    end

    def delete_chunks(hash : Bytes, source_id : Int64, source_type : String) : Int32
      @db.exec("DELETE FROM memo_chunks WHERE hash = ? AND source_id = ? AND source_type = ?", hash, source_id, source_type).rows_affected.to_i
    end

    def delete_chunks(hash : Bytes, source_id : Int64) : Int32
      @db.exec("DELETE FROM memo_chunks WHERE hash = ? AND source_id = ?", hash, source_id).rows_affected.to_i
    end

    def count_chunks_by_hash(hash : Bytes) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_chunks WHERE hash = ?", hash).as(Int64)
    end

    def delete_embeddings_by_hash(hash : Bytes) : Nil
      @db.exec("DELETE FROM memo_embeddings WHERE hash = ?", hash)
    end

    # =========================================================================
    # Sources
    # =========================================================================

    def insert_source(source_type : String, created_at : Int64) : Int64
      @db.exec("INSERT INTO memo_sources (source_type, created_at) VALUES (?, ?)", source_type, created_at).last_insert_id
    end

    def insert_source_int(source_type : String, external_id : Int64, created_at : Int64) : Int64
      @db.exec("INSERT INTO memo_sources (source_type, external_int, created_at) VALUES (?, ?, ?)", source_type, external_id, created_at).last_insert_id
    end

    def insert_source_text(source_type : String, external_id : String, created_at : Int64) : Int64
      @db.exec("INSERT INTO memo_sources (source_type, external_text, created_at) VALUES (?, ?, ?)", source_type, external_id, created_at).last_insert_id
    end

    def insert_source_blob(source_type : String, external_id : Bytes, created_at : Int64) : Int64
      @db.exec("INSERT INTO memo_sources (source_type, external_blob, created_at) VALUES (?, ?, ?)", source_type, external_id, created_at).last_insert_id
    end

    def find_source_int(source_type : String, external_id : Int64) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE source_type = ? AND external_int = ?", source_type, external_id, as: Int64)
    end

    def find_source_text(source_type : String, external_id : String) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE source_type = ? AND external_text = ?", source_type, external_id, as: Int64)
    end

    def find_source_blob(source_type : String, external_id : Bytes) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE source_type = ? AND external_blob = ?", source_type, external_id, as: Int64)
    end

    def find_source_int_any_type(external_id : Int64) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE external_int = ?", external_id, as: Int64)
    end

    def find_source_text_any_type(external_id : String) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE external_text = ?", external_id, as: Int64)
    end

    def find_source_blob_any_type(external_id : Bytes) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE external_blob = ?", external_id, as: Int64)
    end

    def get_source_external(internal_id : Int64) : {String, Int64?, String?, Bytes?}?
      @db.query_one?(
        "SELECT source_type, external_int, external_text, external_blob FROM memo_sources WHERE id = ?",
        internal_id
      ) do |rs|
        {rs.read(String), rs.read(Int64?), rs.read(String?), rs.read(Bytes?)}
      end
    end

    def delete_source_int(source_type : String, external_id : Int64) : Int64
      @db.exec("DELETE FROM memo_sources WHERE source_type = ? AND external_int = ?", source_type, external_id).rows_affected
    end

    def delete_source_text(source_type : String, external_id : String) : Int64
      @db.exec("DELETE FROM memo_sources WHERE source_type = ? AND external_text = ?", source_type, external_id).rows_affected
    end

    def delete_source_blob(source_type : String, external_id : Bytes) : Int64
      @db.exec("DELETE FROM memo_sources WHERE source_type = ? AND external_blob = ?", source_type, external_id).rows_affected
    end

    def delete_source_by_id(internal_id : Int64) : Int64
      @db.exec("DELETE FROM memo_sources WHERE id = ?", internal_id).rows_affected
    end

    def list_sources(source_type : String, limit : Int32, offset : Int32) : Array({Int64, Int64?, String?, Bytes?})
      results = [] of {Int64, Int64?, String?, Bytes?}
      @db.query(
        "SELECT id, external_int, external_text, external_blob FROM memo_sources
         WHERE source_type = ? ORDER BY COALESCE(external_int, 0), external_text LIMIT ? OFFSET ?",
        source_type, limit, offset
      ) do |rs|
        rs.each { results << {rs.read(Int64), rs.read(Int64?), rs.read(String?), rs.read(Bytes?)} }
      end
      results
    end

    # =========================================================================
    # Files
    # =========================================================================

    def upsert_file(source_id : Int64, path : String, content_hash : Bytes, mtime : Int64, size : Int64, created_at : Int64) : Nil
      @db.exec(
        "INSERT OR REPLACE INTO memo_files (source_id, path, content_hash, mtime, size, created_at)
         VALUES (?, ?, ?, ?, ?, ?)",
        source_id, path, content_hash, mtime, size, created_at
      )
    end

    def get_file_by_path(path : String) : Files::FileRecord?
      @db.query_one?("SELECT source_id, path, content_hash, mtime, size FROM memo_files WHERE path = ?", path) do |rs|
        read_file_record(rs)
      end
    end

    def get_file_by_hash(hash : Bytes) : Files::FileRecord?
      @db.query_one?("SELECT source_id, path, content_hash, mtime, size FROM memo_files WHERE content_hash = ?", hash) do |rs|
        read_file_record(rs)
      end
    end

    def get_file_by_source(source_id : Int64) : Files::FileRecord?
      @db.query_one?("SELECT source_id, path, content_hash, mtime, size FROM memo_files WHERE source_id = ?", source_id) do |rs|
        read_file_record(rs)
      end
    end

    def delete_file(source_id : Int64) : Int64
      @db.exec("DELETE FROM memo_files WHERE source_id = ?", source_id).rows_affected
    end

    def list_files(limit : Int32, offset : Int32) : Array(Files::FileRecord)
      records = [] of Files::FileRecord
      @db.query("SELECT source_id, path, content_hash, mtime, size FROM memo_files ORDER BY path LIMIT ? OFFSET ?", limit, offset) do |rs|
        rs.each { records << read_file_record(rs) }
      end
      records
    end

    def count_files : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_files").as(Int64)
    end

    # =========================================================================
    # Vocab
    # =========================================================================

    def get_vocab(service_id : Int64, &block : DB::ResultSet ->) : Nil
      @db.query("SELECT word, embedding, frequency FROM memo_vocab WHERE service_id = ?", service_id) do |rs|
        rs.each { block.call(rs) }
      end
    end

    def upsert_vocab(word : String, service_id : Int64, embedding : Bytes, frequency : Int32, created_at : Int64) : Nil
      @db.exec(
        "INSERT OR REPLACE INTO memo_vocab (word, service_id, embedding, frequency, created_at)
         VALUES (?, ?, ?, ?, ?)",
        word, service_id, embedding, frequency, created_at
      )
    end

    def get_existing_words(service_id : Int64, words : Array(String)) : Set(String)
      existing = Set(String).new
      words.each_slice(500) do |batch|
        placeholders = batch.map { "?" }.join(", ")
        @db.query(
          "SELECT word FROM memo_vocab WHERE service_id = ? AND word IN (#{placeholders})",
          args: [service_id] + batch
        ) do |rs|
          rs.each { existing << rs.read(String) }
        end
      end
      existing
    end

    def update_word_frequency(count : Int32, word : String, service_id : Int64) : Nil
      @db.exec("UPDATE memo_vocab SET frequency = frequency + ? WHERE word = ? AND service_id = ?", count, word, service_id)
    end

    def delete_vocab(service_id : Int64) : Nil
      @db.exec("DELETE FROM memo_vocab WHERE service_id = ?", service_id)
    end

    def count_vocab(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_vocab WHERE service_id = ?", service_id).as(Int64)
    end

    # =========================================================================
    # Queue
    # =========================================================================

    def enqueue(source_id : Int64, text : String, created_at : Int64) : Nil
      @db.exec(
        "INSERT INTO memo_embed_queue (source_id, text, status, created_at)
         VALUES (?, ?, -1, ?)
         ON CONFLICT(source_id) DO UPDATE SET
           text = excluded.text,
           status = -1,
           error_message = NULL,
           attempts = 0,
           processed_at = NULL",
        source_id, text, created_at
      )
    end

    def get_pending_queue(limit : Int32) : Array({Int64, Int64, String})
      items = [] of {Int64, Int64, String}
      @db.query(
        "SELECT id, source_id, text FROM memo_embed_queue WHERE status = -1 ORDER BY created_at ASC LIMIT ?",
        limit
      ) do |rs|
        rs.each { items << {rs.read(Int64), rs.read(Int64), rs.read(String)} }
      end
      items
    end

    def mark_queue_success(id : Int64, processed_at : Int64) : Nil
      @db.exec("UPDATE memo_embed_queue SET status = 0, processed_at = ?, attempts = attempts + 1 WHERE id = ?", processed_at, id)
    end

    def get_queue_attempts(id : Int64) : Int32
      @db.query_one("SELECT attempts FROM memo_embed_queue WHERE id = ?", id, as: Int32)
    end

    def mark_queue_failed(id : Int64, error_message : String?, attempts : Int32, processed_at : Int64) : Nil
      @db.exec(
        "UPDATE memo_embed_queue SET status = 1, error_message = ?, attempts = ?, processed_at = ? WHERE id = ?",
        error_message, attempts, processed_at, id
      )
    end

    def mark_queue_retry(id : Int64, attempts : Int32, error_message : String?) : Nil
      @db.exec("UPDATE memo_embed_queue SET attempts = ?, error_message = ? WHERE id = ?", attempts, error_message, id)
    end

    def get_queue_item(source_id : Int64) : {Int64, String}?
      @db.query_one?("SELECT id, text FROM memo_embed_queue WHERE source_id = ? AND status = -1", source_id, as: {Int64, String})
    end

    def mark_queue_item_success(id : Int64, processed_at : Int64, attempts : Int32) : Nil
      @db.exec("UPDATE memo_embed_queue SET status = 0, processed_at = ?, attempts = ? WHERE id = ?", processed_at, attempts, id)
    end

    def queue_stats : {Int64, Int64}
      pending = @db.scalar("SELECT COUNT(*) FROM memo_embed_queue WHERE status = -1").as(Int64)
      failed = @db.scalar("SELECT COUNT(*) FROM memo_embed_queue WHERE status > 0").as(Int64)
      {pending, failed}
    end

    def clear_completed_queue : Int32
      @db.exec("DELETE FROM memo_embed_queue WHERE status = 0").rows_affected.to_i
    end

    def clear_queue : Int32
      @db.exec("DELETE FROM memo_embed_queue").rows_affected.to_i
    end

    # =========================================================================
    # Texts
    # =========================================================================

    def upsert_text(source_id : Int64, content : String, content_hash : Bytes?, created_at : Int64) : Nil
      @db.exec(
        "INSERT OR REPLACE INTO memo_texts (source_id, content, content_hash, created_at) VALUES (?, ?, ?, ?)",
        source_id, content, content_hash, created_at
      )
    end

    def get_text_hash(source_id : Int64) : Bytes?
      @db.query_one?("SELECT content_hash FROM memo_texts WHERE source_id = ?", source_id, as: Bytes?)
    end

    def delete_text(source_id : Int64) : Nil
      @db.exec("DELETE FROM memo_texts WHERE source_id = ?", source_id)
    end

    def get_text(source_id : Int64) : String?
      @db.query_one?("SELECT content FROM memo_texts WHERE source_id = ?", source_id, as: String)
    end

    def get_all_texts : Array(String)
      texts = [] of String
      @db.query("SELECT content FROM memo_texts") do |rs|
        rs.each { texts << rs.read(String) }
      end
      texts
    end

    def get_service_tokens_per_byte(service_id : Int64) : Float64?
      @db.query_one?("SELECT tokens_per_byte FROM memo_services WHERE id = ?", service_id, as: Float64)
    end

    # =========================================================================
    # Stats (Service-level)
    # =========================================================================

    def count_service_embeddings(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_embeddings WHERE service_id = ?", service_id).as(Int64)
    end

    def count_service_chunks(service_id : Int64) : Int64
      @db.scalar(
        "SELECT COUNT(*) FROM memo_chunks c JOIN memo_embeddings e ON c.hash = e.hash WHERE e.service_id = ?",
        service_id
      ).as(Int64)
    end

    def count_service_sources(service_id : Int64) : Int64
      @db.scalar(
        "SELECT COUNT(DISTINCT c.source_id) FROM memo_chunks c JOIN memo_embeddings e ON c.hash = e.hash WHERE e.service_id = ?",
        service_id
      ).as(Int64)
    end

    # =========================================================================
    # Reindex
    # =========================================================================

    def get_texts_for_reindex(source_type : String) : Array({Int64, Int64?, Int64?, String})
      results = [] of {Int64, Int64?, Int64?, String}
      @db.query(
        "SELECT st.source_id, c.pair_id, c.parent_id, st.content
         FROM memo_texts st
         JOIN memo_sources s ON st.source_id = s.id
         LEFT JOIN memo_chunks c ON st.source_id = c.source_id
         WHERE s.source_type = ?
         GROUP BY st.source_id",
        source_type
      ) do |rs|
        rs.each { results << {rs.read(Int64), rs.read(Int64?), rs.read(Int64?), rs.read(String)} }
      end
      results
    end

    def get_chunks_for_reindex(source_type : String, service_id : Int64) : Array({Int64, Int64?, String?, Int64?, Int64?})
      results = [] of {Int64, Int64?, String?, Int64?, Int64?}
      @db.query(
        "SELECT DISTINCT c.source_id, s.external_int, s.external_text, c.pair_id, c.parent_id
         FROM memo_chunks c
         JOIN memo_embeddings e ON c.hash = e.hash
         JOIN memo_sources s ON c.source_id = s.id
         WHERE c.source_type = ? AND e.service_id = ?",
        source_type, service_id
      ) do |rs|
        rs.each { results << {rs.read(Int64), rs.read(Int64?), rs.read(String?), rs.read(Int64?), rs.read(Int64?)} }
      end
      results
    end

    # =========================================================================
    # Search
    # =========================================================================

    def search_filtered_rowids(
      service_id : Int64,
      params : Array(DB::Any),
      where_clauses : Array(String),
      text_join : String,
      fts_join : String,
    ) : Set(UInt64)
      valid_rowids = Set(UInt64).new
      @db.query(
        <<-SQL,
          SELECT DISTINCT e.rowid
          FROM memo_chunks c
          JOIN memo_embeddings e ON c.hash = e.hash AND e.service_id = ?
          #{text_join}
          #{fts_join}
          WHERE #{where_clauses.join(" AND ")}
        SQL
        args: [service_id] + params
      ) do |rs|
        rs.each { valid_rowids << rs.read(Int64).to_u64 }
      end
      valid_rowids
    end

    def filter_candidates(
      service_id : Int64,
      params : Array(DB::Any),
      where_clauses : Array(String),
      text_join : String,
      fts_join : String,
      candidate_ids : Array(Int64),
    ) : Set(UInt64)
      passing = Set(UInt64).new
      return passing if candidate_ids.empty?

      # CROSS JOIN fixes the join order and INDEXED BY the chunk lookup.
      # Without table statistics SQLite otherwise starts from whatever the
      # filter names (e.g. every chunk of a source_type), costing time in
      # proportion to the collection.
      placeholders = Array.new(candidate_ids.size, "?").join(", ")
      @db.query(
        <<-SQL,
          SELECT DISTINCT e.rowid
          FROM memo_embeddings e
          CROSS JOIN memo_chunks c INDEXED BY memo_idx_chunks_hash ON c.hash = e.hash
          #{text_join}
          #{fts_join}
          WHERE e.rowid IN (#{placeholders}) AND #{where_clauses.join(" AND ")}
        SQL
        args: candidate_ids.map(&.as(DB::Any)) + params
      ) do |rs|
        rs.each { passing << rs.read(Int64).to_u64 }
      end
      passing
    end

    def fetch_search_results(
      rowids : Array(Int64),
      service_id : Int64,
      include_text : Bool,
    ) : Array({UInt64, Int64, Bytes, String, Int64, Int64?, String?, Bytes?, Int64?, Int64?, String?, Bytes?, Int64?, Int64?, String?, Bytes?, Int32?, Int32, Int32, Int32, String?})
      text_select = include_text ? ", SUBSTR(st.content, c.offset + 1, c.size) AS chunk_text" : ""
      text_join = include_text ? "LEFT JOIN memo_texts st ON c.source_id = st.source_id" : ""
      placeholders = rowids.map { "?" }.join(", ")

      results = [] of {UInt64, Int64, Bytes, String, Int64, Int64?, String?, Bytes?, Int64?, Int64?, String?, Bytes?, Int64?, Int64?, String?, Bytes?, Int32?, Int32, Int32, Int32, String?}
      @db.query(
        <<-SQL,
          SELECT e.rowid, c.id, c.hash, c.source_type, c.source_id,
                 s.external_int, s.external_text, s.external_blob,
                 c.pair_id, ps.external_int, ps.external_text, ps.external_blob,
                 c.parent_id, prs.external_int, prs.external_text, prs.external_blob,
                 c.offset, c.size, c.match_count, c.read_count
                 #{text_select}
          FROM memo_embeddings e
          JOIN memo_chunks c ON c.hash = e.hash
          JOIN memo_sources s ON c.source_id = s.id
          LEFT JOIN memo_sources ps ON c.pair_id = ps.id
          LEFT JOIN memo_sources prs ON c.parent_id = prs.id
          #{text_join}
          WHERE e.rowid IN (#{placeholders})
            AND e.service_id = ?
        SQL
        args: rowids.map(&.as(DB::Any)) + [service_id.as(DB::Any)]
      ) do |rs|
        rs.each do
          results << {
            rs.read(Int64).to_u64,
            rs.read(Int64), rs.read(Bytes), rs.read(String), rs.read(Int64),
            rs.read(Int64?), rs.read(String?), rs.read(Bytes?),
            rs.read(Int64?), rs.read(Int64?), rs.read(String?), rs.read(Bytes?),
            rs.read(Int64?), rs.read(Int64?), rs.read(String?), rs.read(Bytes?),
            rs.read(Int32?), rs.read(Int32), rs.read(Int32), rs.read(Int32),
            include_text ? rs.read(String?) : nil,
          }
        end
      end
      results
    end

    # =========================================================================
    # Query Cache
    # =========================================================================

    def get_query_cache(query : String, service_id : Int64) : {Bytes, Int32}?
      @db.query_one?(
        "SELECT embedding, token_count FROM memo_query_cache WHERE query = ? AND service_id = ?",
        query, service_id
      ) { |rs| {rs.read(Bytes), rs.read(Int32)} }
    end

    def upsert_query_cache(query : String, service_id : Int64, embedding : Bytes, token_count : Int32, created_at : Int64) : Nil
      @db.exec(
        "INSERT OR REPLACE INTO memo_query_cache (query, service_id, embedding, token_count, created_at)
         VALUES (?, ?, ?, ?, ?)",
        query, service_id, embedding, token_count, created_at
      )
    end

    def count_query_cache(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_query_cache WHERE service_id = ?", service_id).as(Int64)
    end

    def prune_query_cache(service_id : Int64, count : Int64) : Nil
      @db.exec(
        "DELETE FROM memo_query_cache WHERE rowid IN (
           SELECT rowid FROM memo_query_cache WHERE service_id = ? ORDER BY created_at ASC LIMIT ?
         )", service_id, count
      )
    end

    def clear_query_cache(service_id : Int64) : Nil
      @db.exec("DELETE FROM memo_query_cache WHERE service_id = ?", service_id)
    end

    def get_recent_query_cache(service_id : Int64, limit : Int32) : Array({String, Bytes, Int32})
      results = [] of {String, Bytes, Int32}
      @db.query(
        "SELECT query, embedding, token_count FROM memo_query_cache
         WHERE service_id = ? ORDER BY created_at DESC LIMIT ?",
        service_id, limit
      ) do |rs|
        rs.each { results << {rs.read(String), rs.read(Bytes), rs.read(Int32)} }
      end
      results
    end

    # =========================================================================
    # Vectors and index journal
    # =========================================================================

    def upsert_vector(embedding_id : Int64, service_id : Int64, vector : Bytes) : Nil
      @db.exec(
        "INSERT OR REPLACE INTO memo_vectors (embedding_id, service_id, vector) VALUES (?, ?, ?)",
        embedding_id, service_id, vector
      )
    end

    def get_vector(embedding_id : Int64) : Bytes?
      @db.query_one?("SELECT vector FROM memo_vectors WHERE embedding_id = ?", embedding_id, as: Bytes)
    end

    def delete_vector(embedding_id : Int64) : Nil
      @db.exec("DELETE FROM memo_vectors WHERE embedding_id = ?", embedding_id)
    end

    def count_vectors(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_vectors WHERE service_id = ?", service_id).as(Int64)
    end

    def vectors_after(service_id : Int64, after_id : Int64, limit : Int32) : Array({Int64, Bytes})
      vectors = [] of {Int64, Bytes}
      @db.query(
        "SELECT embedding_id, vector FROM memo_vectors
         WHERE service_id = ? AND embedding_id > ? ORDER BY embedding_id LIMIT ?",
        service_id, after_id, limit
      ) do |rs|
        rs.each { vectors << {rs.read(Int64), rs.read(Bytes)} }
      end
      vectors
    end

    def embedding_ids_for_hash(hash : Bytes) : Array({Int64, Int64})
      ids = [] of {Int64, Int64}
      @db.query("SELECT rowid, service_id FROM memo_embeddings WHERE hash = ?", hash) do |rs|
        rs.each { ids << {rs.read(Int64), rs.read(Int64)} }
      end
      ids
    end

    def embedding_ids_without_vectors(service_id : Int64) : Array(Int64)
      ids = [] of Int64
      @db.query(
        "SELECT e.rowid FROM memo_embeddings e
         LEFT JOIN memo_vectors v ON v.embedding_id = e.rowid
         WHERE e.service_id = ? AND v.embedding_id IS NULL",
        service_id
      ) do |rs|
        rs.each { ids << rs.read(Int64) }
      end
      ids
    end

    def log_index_change(service_id : Int64, embedding_id : Int64) : Nil
      @db.exec("INSERT INTO memo_index_log (service_id, embedding_id) VALUES (?, ?)", service_id, embedding_id)
    end

    def index_changes_since(service_id : Int64, seq : Int64) : Array(Int64)
      ids = [] of Int64
      @db.query(
        "SELECT DISTINCT embedding_id FROM memo_index_log WHERE service_id = ? AND seq > ?",
        service_id, seq
      ) do |rs|
        rs.each { ids << rs.read(Int64) }
      end
      ids
    end

    def max_index_log_seq(service_id : Int64) : Int64
      @db.scalar("SELECT COALESCE(MAX(seq), 0) FROM memo_index_log WHERE service_id = ?", service_id).as(Int64)
    end

    def prune_index_log(service_id : Int64, through : Int64) : Nil
      @db.exec("DELETE FROM memo_index_log WHERE service_id = ? AND seq <= ?", service_id, through)
    end

    def get_index_state(service_id : Int64) : {Int64, Bool}?
      @db.query_one?(
        "SELECT pruned_through, vectors_backfilled FROM memo_index_state WHERE service_id = ?",
        service_id
      ) { |rs| {rs.read(Int64), rs.read(Int64) == 1} }
    end

    def set_index_pruned_through(service_id : Int64, seq : Int64) : Nil
      @db.exec(
        "INSERT INTO memo_index_state (service_id, pruned_through) VALUES (?, ?)
         ON CONFLICT(service_id) DO UPDATE SET pruned_through = excluded.pruned_through",
        service_id, seq
      )
    end

    def set_vectors_backfilled(service_id : Int64) : Nil
      @db.exec(
        "INSERT INTO memo_index_state (service_id, vectors_backfilled) VALUES (?, 1)
         ON CONFLICT(service_id) DO UPDATE SET vectors_backfilled = 1",
        service_id
      )
    end

    def delete_index_data(service_id : Int64) : Nil
      @db.exec("DELETE FROM memo_vectors WHERE service_id = ?", service_id)
      @db.exec("DELETE FROM memo_index_log WHERE service_id = ?", service_id)
      @db.exec("DELETE FROM memo_index_state WHERE service_id = ?", service_id)
    end

    # =========================================================================
    # Clustering
    # =========================================================================

    def load_embedding_rowids(
      service_id : Int64,
      source_type : String,
      external_ids : Array(Int64),
    ) : Array({Int64, Int64})
      results = [] of {Int64, Int64}
      placeholders = external_ids.map { "?" }.join(", ")
      @db.query(
        <<-SQL,
          SELECT s.external_int, e.rowid
          FROM memo_sources s
          JOIN memo_chunks c ON c.source_id = s.id
          JOIN memo_embeddings e ON c.hash = e.hash AND e.service_id = ?
          WHERE s.source_type = ?
            AND s.external_int IN (#{placeholders})
          GROUP BY s.external_int
          ORDER BY s.external_int, c.offset
        SQL
        args: [service_id, source_type] + external_ids.map(&.as(DB::Any))
      ) do |rs|
        rs.each { results << {rs.read(Int64), rs.read(Int64)} }
      end
      results
    end

    # =========================================================================
    # Helpers
    # =========================================================================

    private def read_service_info(rs) : ServiceProvider::Info
      ServiceProvider::Info.new(
        id: rs.read(Int64), name: rs.read(String), format: rs.read(String),
        base_url: rs.read(String?), model: rs.read(String),
        dimensions: rs.read(Int32), max_tokens: rs.read(Int32),
        tokens_per_byte: rs.read(Float64), is_default: rs.read(Int32) == 1,
        created_at: Time.unix_ms(rs.read(Int64))
      )
    end

    private def read_file_record(rs) : Files::FileRecord
      Files::FileRecord.new(rs.read(Int64), rs.read(String), rs.read(Bytes), rs.read(Int64), rs.read(Int64))
    end
  end
end
