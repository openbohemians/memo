module Memo
  class Queries::Postgres < Queries
    def for_connection(cnn : DB::Connection) : Queries
      Postgres.new(cnn)
    end

    # Number the clauses' `?` placeholders $N, continuing after `after`.
    # Returns the clauses and the last number used. Skips quoted strings
    # ('...', "...", $tag$...$tag$) and comments, so a literal `?` in caller
    # SQL (sql_where) isn't taken for a placeholder. That is also why the
    # jsonb ?, ?| and ?& operators can't appear in sql_where on Postgres:
    # use jsonb_exists, jsonb_exists_any and jsonb_exists_all instead.
    def self.number_placeholders(clauses : Array(String), after : Int32) : {Array(String), Int32}
      n = after
      numbered = clauses.map do |clause|
        bytes = clause.to_slice
        String.build do |io|
          i = 0
          while i < bytes.size
            skip_to = skip_quoted(bytes, i)
            if skip_to > i
              io.write(bytes[i, skip_to - i])
              i = skip_to
            elsif bytes[i] == '?'.ord
              n += 1
              io << '$' << n
              i += 1
            else
              io.write_byte(bytes[i])
              i += 1
            end
          end
        end
      end
      {numbered, n}
    end

    # If a quoted string or comment starts at `i`, the index just past it;
    # otherwise `i`. Works on bytes: no multi-byte UTF-8 character contains
    # an ASCII byte, so quotes and `?` can't be mistaken.
    private def self.skip_quoted(bytes : Bytes, i : Int32) : Int32
      byte = bytes[i]
      after = bytes[i + 1]?
      if byte == '\''.ord || byte == '"'.ord # 'string' or "identifier"; doubled quote escapes
        j = i + 1
        while j < bytes.size
          if bytes[j] == byte
            return j + 1 unless bytes[j + 1]? == byte
            j += 2
          else
            j += 1
          end
        end
        bytes.size
      elsif byte == '-'.ord && after == '-'.ord # -- comment, to end of line
        (i...bytes.size).find { |j| bytes[j] == '\n'.ord } || bytes.size
      elsif byte == '/'.ord && after == '*'.ord # /* comment */
        j = i + 2
        while j + 1 < bytes.size
          return j + 2 if bytes[j] == '*'.ord && bytes[j + 1] == '/'.ord
          j += 1
        end
        bytes.size
      elsif byte == '$'.ord # $$ or $tag$ dollar quote ($1 is a parameter)
        j = i + 1
        while j < bytes.size && (bytes[j].unsafe_chr.ascii_alphanumeric? || bytes[j] == '_'.ord)
          j += 1
        end
        return i unless j < bytes.size && bytes[j] == '$'.ord && !after.try(&.unsafe_chr.ascii_number?)
        tag = bytes[i..j]
        k = j + 1
        while k + tag.size <= bytes.size
          return k + tag.size if bytes[k, tag.size] == tag
          k += 1
        end
        bytes.size
      else
        i
      end
    end

    # =========================================================================
    # Services
    # =========================================================================

    def find_service_id(name : String) : Int64?
      @db.query_one?("SELECT id FROM memo_services WHERE name = $1", name, as: Int64)
    end

    def insert_service(
      name : String, format : String, base_url : String?,
      model : String, dimensions : Int32, max_tokens : Int32, created_at : Int64,
    ) : Int64
      @db.scalar(
        "INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id",
        name, format, base_url, model, dimensions, max_tokens, created_at
      ).as(Int64)
    end

    def get_service_by_name(name : String) : {Int64, String, String?, String, Int32, Int32, Float64}?
      @db.query_one?(
        "SELECT id, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25)
         FROM memo_services WHERE name = $1", name
      ) do |rs|
        {rs.read(Int64), rs.read(String), rs.read(String?), rs.read(String), rs.read(Int32), rs.read(Int32), rs.read(Float64)}
      end
    end

    def get_service_by_format_model(format : String, model : String) : {Int64, String, String?, String, Int32, Int32, Float64}?
      @db.query_one?(
        "SELECT id, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25)
         FROM memo_services WHERE format = $1 AND model = $2", format, model
      ) do |rs|
        {rs.read(Int64), rs.read(String), rs.read(String?), rs.read(String), rs.read(Int32), rs.read(Int32), rs.read(Float64)}
      end
    end

    def get_tokens_per_byte(service_id : Int64) : Float64?
      @db.query_one?("SELECT COALESCE(tokens_per_byte, 0.25) FROM memo_services WHERE id = $1", service_id, as: Float64)
    end

    def update_tokens_per_byte(tokens_per_byte : Float64, service_id : Int64) : Nil
      @db.exec("UPDATE memo_services SET tokens_per_byte = $1 WHERE id = $2", tokens_per_byte, service_id)
    end

    def get_service_info(id : Int64) : ServiceProvider::Info?
      @db.query_one?(
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25), is_default, created_at
         FROM memo_services WHERE id = $1", id
      ) { |rs| read_service_info(rs) }
    end

    def get_service_info_by_name(name : String) : ServiceProvider::Info?
      @db.query_one?(
        "SELECT id, name, format, base_url, model, dimensions, max_tokens, COALESCE(tokens_per_byte, 0.25), is_default, created_at
         FROM memo_services WHERE name = $1", name
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
      @db.exec("UPDATE memo_services SET is_default = 1 WHERE id = $1", id)
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
         FROM memo_services WHERE format = $1 ORDER BY created_at DESC", format
      ) { |rs| rs.each { services << read_service_info(rs) } }
      services
    end

    def update_service(id : Int64, updates : Array(String), params : Array(DB::Any)) : Int64
      # Rewrite ? placeholders to $N for dynamic updates
      offset = 0
      pg_updates = updates.map do |u|
        offset += 1
        u.gsub("?", "$#{offset}")
      end
      pg_params = params + [id.as(DB::Any)]
      @db.exec("UPDATE memo_services SET #{pg_updates.join(", ")} WHERE id = $#{offset + 1}", args: pg_params)
      id
    end

    def get_embedding_hashes_for_service(service_id : Int64) : Array(Bytes)
      hashes = [] of Bytes
      @db.query("SELECT hash FROM memo_embeddings WHERE service_id = $1", service_id) do |rs|
        rs.each { hashes << rs.read(Bytes) }
      end
      hashes
    end

    def delete_chunks_by_hash(hash : Bytes) : Nil
      @db.exec("DELETE FROM memo_chunks WHERE hash = $1", hash)
    end

    def delete_embeddings_by_service(service_id : Int64) : Nil
      @db.exec("DELETE FROM memo_embeddings WHERE service_id = $1", service_id)
    end

    def delete_service(id : Int64) : Nil
      @db.exec("DELETE FROM memo_services WHERE id = $1", id)
    end

    def count_embeddings_for_service(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_embeddings WHERE service_id = $1", service_id).as(Int64)
    end

    def count_chunks_for_service(service_id : Int64) : Int64
      @db.scalar(
        "SELECT COUNT(*) FROM memo_chunks c JOIN memo_embeddings e ON c.hash = e.hash WHERE e.service_id = $1",
        service_id
      ).as(Int64)
    end

    def service_exists?(id : Int64) : Bool
      @db.scalar("SELECT COUNT(*) FROM memo_services WHERE id = $1", id).as(Int64) > 0
    end

    def count_services : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_services").as(Int64)
    end

    def insert_service_full(
      name : String, format : String, base_url : String?,
      model : String, dimensions : Int32, max_tokens : Int32,
      is_default : Int32, created_at : Int64,
    ) : Int64
      @db.scalar(
        "INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
        name, format, base_url, model, dimensions, max_tokens, is_default, created_at
      ).as(Int64)
    end

    # =========================================================================
    # Embeddings
    # =========================================================================

    def insert_embedding_ignore(hash : Bytes, service_id : Int64, token_count : Int32, created_at : Int64) : Int64
      @db.exec(
        "INSERT INTO memo_embeddings (hash, service_id, token_count, created_at)
         VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
        hash, service_id, token_count, created_at
      )
      @db.query_one("SELECT eid FROM memo_embeddings WHERE hash = $1 AND service_id = $2", hash, service_id, as: Int64)
    end

    def get_embedding_rowid(hash : Bytes, service_id : Int64) : Int64
      @db.query_one("SELECT eid FROM memo_embeddings WHERE hash = $1 AND service_id = $2", hash, service_id, as: Int64)
    end

    def get_embedding_rowid?(hash : Bytes, service_id : Int64) : Int64?
      @db.query_one?("SELECT eid FROM memo_embeddings WHERE hash = $1 AND service_id = $2", hash, service_id, as: Int64)
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
        "INSERT INTO memo_chunks (hash, source_id, source_type, pair_id, parent_id, \"offset\", size, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT DO NOTHING",
        hash, source_id, source_type, pair_id, parent_id, offset, size, created_at
      )
      return 0_i64 if result.rows_affected == 0
      @db.query_one("SELECT id FROM memo_chunks WHERE source_id = $1 AND \"offset\" IS NOT DISTINCT FROM $2", source_id, offset, as: Int64)
    end

    def get_chunk_id(source_id : Int64, offset : Int32?) : Int64
      @db.query_one("SELECT id FROM memo_chunks WHERE source_id = $1 AND \"offset\" IS NOT DISTINCT FROM $2", source_id, offset, as: Int64)
    end

    def increment_match_count(chunk_ids : Array(Int64)) : Nil
      return if chunk_ids.empty?
      placeholders = chunk_ids.each_with_index.map { |_, i| "$#{i + 1}" }.join(", ")
      @db.exec("UPDATE memo_chunks SET match_count = match_count + 1 WHERE id IN (#{placeholders})", args: chunk_ids)
    end

    def increment_read_count(chunk_ids : Array(Int64)) : Nil
      return if chunk_ids.empty?
      placeholders = chunk_ids.each_with_index.map { |_, i| "$#{i + 1}" }.join(", ")
      @db.exec("UPDATE memo_chunks SET read_count = read_count + 1 WHERE id IN (#{placeholders})", args: chunk_ids)
    end

    def get_chunk_hashes(source_id : Int64, source_type : String?) : Array(Bytes)
      hashes = [] of Bytes
      if source_type
        @db.query("SELECT DISTINCT hash FROM memo_chunks WHERE source_id = $1 AND source_type = $2", source_id, source_type) do |rs|
          rs.each { hashes << rs.read(Bytes) }
        end
      else
        @db.query("SELECT DISTINCT hash FROM memo_chunks WHERE source_id = $1", source_id) do |rs|
          rs.each { hashes << rs.read(Bytes) }
        end
      end
      hashes
    end

    def delete_chunks(hash : Bytes, source_id : Int64, source_type : String) : Int32
      @db.exec("DELETE FROM memo_chunks WHERE hash = $1 AND source_id = $2 AND source_type = $3", hash, source_id, source_type).rows_affected.to_i
    end

    def delete_chunks(hash : Bytes, source_id : Int64) : Int32
      @db.exec("DELETE FROM memo_chunks WHERE hash = $1 AND source_id = $2", hash, source_id).rows_affected.to_i
    end

    def count_chunks_by_hash(hash : Bytes) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_chunks WHERE hash = $1", hash).as(Int64)
    end

    def delete_embeddings_by_hash(hash : Bytes) : Nil
      @db.exec("DELETE FROM memo_embeddings WHERE hash = $1", hash)
    end

    # =========================================================================
    # Sources
    # =========================================================================

    def insert_source(source_type : String, created_at : Int64) : Int64
      @db.scalar("INSERT INTO memo_sources (source_type, created_at) VALUES ($1, $2) RETURNING id", source_type, created_at).as(Int64)
    end

    def insert_source_int(source_type : String, external_id : Int64, created_at : Int64) : Int64
      @db.scalar("INSERT INTO memo_sources (source_type, external_int, created_at) VALUES ($1, $2, $3) RETURNING id", source_type, external_id, created_at).as(Int64)
    end

    def insert_source_text(source_type : String, external_id : String, created_at : Int64) : Int64
      @db.scalar("INSERT INTO memo_sources (source_type, external_text, created_at) VALUES ($1, $2, $3) RETURNING id", source_type, external_id, created_at).as(Int64)
    end

    def insert_source_blob(source_type : String, external_id : Bytes, created_at : Int64) : Int64
      @db.scalar("INSERT INTO memo_sources (source_type, external_blob, created_at) VALUES ($1, $2, $3) RETURNING id", source_type, external_id, created_at).as(Int64)
    end

    def find_source_int(source_type : String, external_id : Int64) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE source_type = $1 AND external_int = $2", source_type, external_id, as: Int64)
    end

    def find_source_text(source_type : String, external_id : String) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE source_type = $1 AND external_text = $2", source_type, external_id, as: Int64)
    end

    def find_source_blob(source_type : String, external_id : Bytes) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE source_type = $1 AND external_blob = $2", source_type, external_id, as: Int64)
    end

    def find_source_int_any_type(external_id : Int64) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE external_int = $1", external_id, as: Int64)
    end

    def find_source_text_any_type(external_id : String) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE external_text = $1", external_id, as: Int64)
    end

    def find_source_blob_any_type(external_id : Bytes) : Int64?
      @db.query_one?("SELECT id FROM memo_sources WHERE external_blob = $1", external_id, as: Int64)
    end

    def get_source_external(internal_id : Int64) : {String, Int64?, String?, Bytes?}?
      @db.query_one?(
        "SELECT source_type, external_int, external_text, external_blob FROM memo_sources WHERE id = $1",
        internal_id
      ) do |rs|
        {rs.read(String), rs.read(Int64?), rs.read(String?), rs.read(Bytes?)}
      end
    end

    def delete_source_int(source_type : String, external_id : Int64) : Int64
      @db.exec("DELETE FROM memo_sources WHERE source_type = $1 AND external_int = $2", source_type, external_id).rows_affected
    end

    def delete_source_text(source_type : String, external_id : String) : Int64
      @db.exec("DELETE FROM memo_sources WHERE source_type = $1 AND external_text = $2", source_type, external_id).rows_affected
    end

    def delete_source_blob(source_type : String, external_id : Bytes) : Int64
      @db.exec("DELETE FROM memo_sources WHERE source_type = $1 AND external_blob = $2", source_type, external_id).rows_affected
    end

    def delete_source_by_id(internal_id : Int64) : Int64
      @db.exec("DELETE FROM memo_sources WHERE id = $1", internal_id).rows_affected
    end

    def list_sources(source_type : String, limit : Int32, offset : Int32) : Array({Int64, Int64?, String?, Bytes?})
      results = [] of {Int64, Int64?, String?, Bytes?}
      @db.query(
        "SELECT id, external_int, external_text, external_blob FROM memo_sources
         WHERE source_type = $1 ORDER BY COALESCE(external_int, 0), external_text LIMIT $2 OFFSET $3",
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
        "INSERT INTO memo_files (source_id, path, content_hash, mtime, size, created_at)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (source_id) DO UPDATE SET
           path = EXCLUDED.path, content_hash = EXCLUDED.content_hash,
           mtime = EXCLUDED.mtime, size = EXCLUDED.size, created_at = EXCLUDED.created_at",
        source_id, path, content_hash, mtime, size, created_at
      )
    end

    def get_file_by_path(path : String) : Files::FileRecord?
      @db.query_one?("SELECT source_id, path, content_hash, mtime, size FROM memo_files WHERE path = $1", path) do |rs|
        read_file_record(rs)
      end
    end

    def get_file_by_hash(hash : Bytes) : Files::FileRecord?
      @db.query_one?("SELECT source_id, path, content_hash, mtime, size FROM memo_files WHERE content_hash = $1", hash) do |rs|
        read_file_record(rs)
      end
    end

    def get_file_by_source(source_id : Int64) : Files::FileRecord?
      @db.query_one?("SELECT source_id, path, content_hash, mtime, size FROM memo_files WHERE source_id = $1", source_id) do |rs|
        read_file_record(rs)
      end
    end

    def delete_file(source_id : Int64) : Int64
      @db.exec("DELETE FROM memo_files WHERE source_id = $1", source_id).rows_affected
    end

    def list_files(limit : Int32, offset : Int32) : Array(Files::FileRecord)
      records = [] of Files::FileRecord
      @db.query("SELECT source_id, path, content_hash, mtime, size FROM memo_files ORDER BY path LIMIT $1 OFFSET $2", limit, offset) do |rs|
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
      @db.query("SELECT word, embedding, frequency FROM memo_vocab WHERE service_id = $1", service_id) do |rs|
        rs.each { block.call(rs) }
      end
    end

    def upsert_vocab(word : String, service_id : Int64, embedding : Bytes, frequency : Int32, created_at : Int64) : Nil
      @db.exec(
        "INSERT INTO memo_vocab (word, service_id, embedding, frequency, created_at)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (word, service_id) DO UPDATE SET
           embedding = EXCLUDED.embedding, frequency = EXCLUDED.frequency, created_at = EXCLUDED.created_at",
        word, service_id, embedding, frequency, created_at
      )
    end

    def get_existing_words(service_id : Int64, words : Array(String)) : Set(String)
      existing = Set(String).new
      words.each_slice(500) do |batch|
        placeholders = batch.each_with_index.map { |_, i| "$#{i + 2}" }.join(", ")
        @db.query(
          "SELECT word FROM memo_vocab WHERE service_id = $1 AND word IN (#{placeholders})",
          args: [service_id] + batch
        ) do |rs|
          rs.each { existing << rs.read(String) }
        end
      end
      existing
    end

    def update_word_frequency(count : Int32, word : String, service_id : Int64) : Nil
      @db.exec("UPDATE memo_vocab SET frequency = frequency + $1 WHERE word = $2 AND service_id = $3", count, word, service_id)
    end

    def delete_vocab(service_id : Int64) : Nil
      @db.exec("DELETE FROM memo_vocab WHERE service_id = $1", service_id)
    end

    def count_vocab(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_vocab WHERE service_id = $1", service_id).as(Int64)
    end

    # =========================================================================
    # Queue
    # =========================================================================

    def enqueue(source_id : Int64, text : String, created_at : Int64) : Nil
      @db.exec(
        "INSERT INTO memo_embed_queue (source_id, text, status, created_at)
         VALUES ($1, $2, -1, $3)
         ON CONFLICT(source_id) DO UPDATE SET
           text = EXCLUDED.text,
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
        "SELECT id, source_id, text FROM memo_embed_queue WHERE status = -1 ORDER BY created_at ASC LIMIT $1",
        limit
      ) do |rs|
        rs.each { items << {rs.read(Int64), rs.read(Int64), rs.read(String)} }
      end
      items
    end

    def mark_queue_success(id : Int64, processed_at : Int64) : Nil
      @db.exec("UPDATE memo_embed_queue SET status = 0, processed_at = $1, attempts = attempts + 1 WHERE id = $2", processed_at, id)
    end

    def get_queue_attempts(id : Int64) : Int32
      @db.query_one("SELECT attempts FROM memo_embed_queue WHERE id = $1", id, as: Int32)
    end

    def mark_queue_failed(id : Int64, error_message : String?, attempts : Int32, processed_at : Int64) : Nil
      @db.exec(
        "UPDATE memo_embed_queue SET status = 1, error_message = $1, attempts = $2, processed_at = $3 WHERE id = $4",
        error_message, attempts, processed_at, id
      )
    end

    def mark_queue_retry(id : Int64, attempts : Int32, error_message : String?) : Nil
      @db.exec("UPDATE memo_embed_queue SET attempts = $1, error_message = $2 WHERE id = $3", attempts, error_message, id)
    end

    def get_queue_item(source_id : Int64) : {Int64, String}?
      @db.query_one?("SELECT id, text FROM memo_embed_queue WHERE source_id = $1 AND status = -1", source_id, as: {Int64, String})
    end

    def mark_queue_item_success(id : Int64, processed_at : Int64, attempts : Int32) : Nil
      @db.exec("UPDATE memo_embed_queue SET status = 0, processed_at = $1, attempts = $2 WHERE id = $3", processed_at, attempts, id)
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
        "INSERT INTO memo_texts (source_id, content, content_hash, created_at)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (source_id) DO UPDATE SET
           content = EXCLUDED.content, content_hash = EXCLUDED.content_hash, created_at = EXCLUDED.created_at",
        source_id, content, content_hash, created_at
      )
    end

    def get_text_hash(source_id : Int64) : Bytes?
      @db.query_one?("SELECT content_hash FROM memo_texts WHERE source_id = $1", source_id, as: Bytes?)
    end

    def delete_text(source_id : Int64) : Nil
      @db.exec("DELETE FROM memo_texts WHERE source_id = $1", source_id)
    end

    def get_text(source_id : Int64) : String?
      @db.query_one?("SELECT content FROM memo_texts WHERE source_id = $1", source_id, as: String)
    end

    def get_all_texts : Array(String)
      texts = [] of String
      @db.query("SELECT content FROM memo_texts") do |rs|
        rs.each { texts << rs.read(String) }
      end
      texts
    end

    def get_service_tokens_per_byte(service_id : Int64) : Float64?
      @db.query_one?("SELECT tokens_per_byte FROM memo_services WHERE id = $1", service_id, as: Float64)
    end

    # =========================================================================
    # Stats (Service-level)
    # =========================================================================

    def count_service_embeddings(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_embeddings WHERE service_id = $1", service_id).as(Int64)
    end

    def count_service_chunks(service_id : Int64) : Int64
      @db.scalar(
        "SELECT COUNT(*) FROM memo_chunks c JOIN memo_embeddings e ON c.hash = e.hash WHERE e.service_id = $1",
        service_id
      ).as(Int64)
    end

    def count_service_sources(service_id : Int64) : Int64
      @db.scalar(
        "SELECT COUNT(DISTINCT c.source_id) FROM memo_chunks c JOIN memo_embeddings e ON c.hash = e.hash WHERE e.service_id = $1",
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
         WHERE s.source_type = $1
         GROUP BY st.source_id, c.pair_id, c.parent_id, st.content",
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
         WHERE c.source_type = $1 AND e.service_id = $2",
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
      # Rewrite ? placeholders to $N, after $1 (service_id in the JOIN)
      pg_where, _ = Postgres.number_placeholders(where_clauses, after: 1)

      valid_rowids = Set(UInt64).new
      @db.query(
        <<-SQL,
          SELECT DISTINCT e.eid
          FROM memo_chunks c
          JOIN memo_embeddings e ON c.hash = e.hash AND e.service_id = $1
          #{text_join}
          #{fts_join}
          WHERE #{pg_where.join(" AND ")}
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

      # Candidates take $1..$n; rewrite the clauses' ? placeholders after them
      placeholders = (1..candidate_ids.size).join(", ") { |k| "$#{k}" }
      pg_where, _ = Postgres.number_placeholders(where_clauses, after: candidate_ids.size)

      @db.query(
        <<-SQL,
          SELECT DISTINCT e.eid
          FROM memo_embeddings e
          JOIN memo_chunks c ON c.hash = e.hash
          #{text_join}
          #{fts_join}
          WHERE e.eid IN (#{placeholders}) AND #{pg_where.join(" AND ")}
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
      text_select = include_text ? ", SUBSTR(st.content, c.\"offset\" + 1, c.size) AS chunk_text" : ""
      text_join = include_text ? "LEFT JOIN memo_texts st ON c.source_id = st.source_id" : ""

      placeholders = rowids.each_with_index.map { |_, i| "$#{i + 1}" }.join(", ")
      service_param_idx = rowids.size + 1

      results = [] of {UInt64, Int64, Bytes, String, Int64, Int64?, String?, Bytes?, Int64?, Int64?, String?, Bytes?, Int64?, Int64?, String?, Bytes?, Int32?, Int32, Int32, Int32, String?}
      @db.query(
        <<-SQL,
          SELECT e.eid, c.id, c.hash, c.source_type, c.source_id,
                 s.external_int, s.external_text, s.external_blob,
                 c.pair_id, ps.external_int, ps.external_text, ps.external_blob,
                 c.parent_id, prs.external_int, prs.external_text, prs.external_blob,
                 c."offset", c.size, c.match_count, c.read_count
                 #{text_select}
          FROM memo_embeddings e
          JOIN memo_chunks c ON c.hash = e.hash
          JOIN memo_sources s ON c.source_id = s.id
          LEFT JOIN memo_sources ps ON c.pair_id = ps.id
          LEFT JOIN memo_sources prs ON c.parent_id = prs.id
          #{text_join}
          WHERE e.eid IN (#{placeholders})
            AND e.service_id = $#{service_param_idx}
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
        "SELECT embedding, token_count FROM memo_query_cache WHERE query = $1 AND service_id = $2",
        query, service_id
      ) { |rs| {rs.read(Bytes), rs.read(Int32)} }
    end

    def upsert_query_cache(query : String, service_id : Int64, embedding : Bytes, token_count : Int32, created_at : Int64) : Nil
      @db.exec(
        "INSERT INTO memo_query_cache (query, service_id, embedding, token_count, created_at)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (query, service_id) DO UPDATE SET
           embedding = EXCLUDED.embedding, token_count = EXCLUDED.token_count, created_at = EXCLUDED.created_at",
        query, service_id, embedding, token_count, created_at
      )
    end

    def count_query_cache(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_query_cache WHERE service_id = $1", service_id).as(Int64)
    end

    def prune_query_cache(service_id : Int64, count : Int64) : Nil
      @db.exec(
        "DELETE FROM memo_query_cache WHERE ctid IN (
           SELECT ctid FROM memo_query_cache WHERE service_id = $1 ORDER BY created_at ASC LIMIT $2
         )", service_id, count
      )
    end

    def clear_query_cache(service_id : Int64) : Nil
      @db.exec("DELETE FROM memo_query_cache WHERE service_id = $1", service_id)
    end

    def get_recent_query_cache(service_id : Int64, limit : Int32) : Array({String, Bytes, Int32})
      results = [] of {String, Bytes, Int32}
      @db.query(
        "SELECT query, embedding, token_count FROM memo_query_cache
         WHERE service_id = $1 ORDER BY created_at DESC LIMIT $2",
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
        "INSERT INTO memo_vectors (embedding_id, service_id, vector) VALUES ($1, $2, $3)
         ON CONFLICT (embedding_id) DO UPDATE SET service_id = EXCLUDED.service_id, vector = EXCLUDED.vector",
        embedding_id, service_id, vector
      )
    end

    def get_vector(embedding_id : Int64) : Bytes?
      @db.query_one?("SELECT vector FROM memo_vectors WHERE embedding_id = $1", embedding_id, as: Bytes)
    end

    def delete_vector(embedding_id : Int64) : Nil
      @db.exec("DELETE FROM memo_vectors WHERE embedding_id = $1", embedding_id)
    end

    def count_vectors(service_id : Int64) : Int64
      @db.scalar("SELECT COUNT(*) FROM memo_vectors WHERE service_id = $1", service_id).as(Int64)
    end

    def vectors_after(service_id : Int64, after_id : Int64, limit : Int32) : Array({Int64, Bytes})
      vectors = [] of {Int64, Bytes}
      @db.query(
        "SELECT embedding_id, vector FROM memo_vectors
         WHERE service_id = $1 AND embedding_id > $2 ORDER BY embedding_id LIMIT $3",
        service_id, after_id, limit
      ) do |rs|
        rs.each { vectors << {rs.read(Int64), rs.read(Bytes)} }
      end
      vectors
    end

    def embedding_ids_for_hash(hash : Bytes) : Array({Int64, Int64})
      ids = [] of {Int64, Int64}
      @db.query("SELECT eid, service_id FROM memo_embeddings WHERE hash = $1", hash) do |rs|
        rs.each { ids << {rs.read(Int64), rs.read(Int64)} }
      end
      ids
    end

    def embedding_ids_without_vectors(service_id : Int64) : Array(Int64)
      ids = [] of Int64
      @db.query(
        "SELECT e.eid FROM memo_embeddings e
         LEFT JOIN memo_vectors v ON v.embedding_id = e.eid
         WHERE e.service_id = $1 AND v.embedding_id IS NULL",
        service_id
      ) do |rs|
        rs.each { ids << rs.read(Int64) }
      end
      ids
    end

    def log_index_change(service_id : Int64, embedding_id : Int64) : Nil
      @db.exec("INSERT INTO memo_index_log (service_id, embedding_id) VALUES ($1, $2)", service_id, embedding_id)
    end

    def index_changes_since(service_id : Int64, seq : Int64) : Array(Int64)
      ids = [] of Int64
      @db.query(
        "SELECT DISTINCT embedding_id FROM memo_index_log WHERE service_id = $1 AND seq > $2",
        service_id, seq
      ) do |rs|
        rs.each { ids << rs.read(Int64) }
      end
      ids
    end

    def max_index_log_seq(service_id : Int64) : Int64
      @db.scalar("SELECT COALESCE(MAX(seq), 0) FROM memo_index_log WHERE service_id = $1", service_id).as(Int64)
    end

    def prune_index_log(service_id : Int64, through : Int64) : Nil
      @db.exec("DELETE FROM memo_index_log WHERE service_id = $1 AND seq <= $2", service_id, through)
    end

    def get_index_state(service_id : Int64) : {Int64, Bool}?
      @db.query_one?(
        "SELECT pruned_through, vectors_backfilled FROM memo_index_state WHERE service_id = $1",
        service_id
      ) { |rs| {rs.read(Int64), rs.read(Int32) == 1} }
    end

    def set_index_pruned_through(service_id : Int64, seq : Int64) : Nil
      @db.exec(
        "INSERT INTO memo_index_state (service_id, pruned_through) VALUES ($1, $2)
         ON CONFLICT (service_id) DO UPDATE SET pruned_through = EXCLUDED.pruned_through",
        service_id, seq
      )
    end

    def set_vectors_backfilled(service_id : Int64) : Nil
      @db.exec(
        "INSERT INTO memo_index_state (service_id, vectors_backfilled) VALUES ($1, 1)
         ON CONFLICT (service_id) DO UPDATE SET vectors_backfilled = 1",
        service_id
      )
    end

    def delete_index_data(service_id : Int64) : Nil
      @db.exec("DELETE FROM memo_vectors WHERE service_id = $1", service_id)
      @db.exec("DELETE FROM memo_index_log WHERE service_id = $1", service_id)
      @db.exec("DELETE FROM memo_index_state WHERE service_id = $1", service_id)
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
      placeholders = external_ids.each_with_index.map { |_, i| "$#{i + 3}" }.join(", ")
      @db.query(
        <<-SQL,
          SELECT s.external_int, e.eid
          FROM memo_sources s
          JOIN memo_chunks c ON c.source_id = s.id
          JOIN memo_embeddings e ON c.hash = e.hash AND e.service_id = $1
          WHERE s.source_type = $2
            AND s.external_int IN (#{placeholders})
          GROUP BY s.external_int, e.eid
          ORDER BY s.external_int, c."offset"
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
