module Memo
  # Low-level storage operations for embeddings and chunks
  module Storage
    extend self

    # Compute SHA256 hash for text content
    def compute_hash(text : String) : Bytes
      Digest::SHA256.digest(text)
    end

    # Register or get existing service by name
    def register_service(
      db : DBHandle,
      name : String?,
      format : String,
      base_url : String?,
      model : String,
      dimensions : Int32,
      max_tokens : Int32,
    ) : Int64
      q = db.memo_queries
      service_name = name || "#{format}/#{model}"

      service_id = q.find_service_id(service_name)
      return service_id if service_id

      q.insert_service(service_name, format, base_url, model, dimensions, max_tokens, Time.utc.to_unix_ms)
    end

    # Get service by name
    def get_service_by_name(
      db : DBHandle,
      name : String,
    ) : {Int64, String, String?, String, Int32, Int32, Float64}?
      db.memo_queries.get_service_by_name(name)
    end

    # Returns service record by format and model, or nil if not found
    def get_service_by_format_model(
      db : DBHandle,
      format : String,
      model : String,
    ) : {Int64, String, String?, String, Int32, Int32, Float64}?
      db.memo_queries.get_service_by_format_model(format, model)
    end

    # Update tokens_per_byte ratio using exponential moving average
    def update_tokens_per_byte(
      db : DBHandle,
      service_id : Int64,
      observed_ratio : Float64,
    )
      q = db.memo_queries
      current = q.get_tokens_per_byte(service_id) || 0.25
      updated = current * 0.8 + observed_ratio * 0.2
      q.update_tokens_per_byte(updated, service_id)
    end

    # Register embedding hash in database (deduplicated by hash + service_id)
    #
    # Returns {inserted, rowid} where inserted is true if new, rowid is the USearch key.
    def store_embedding(
      db : DBHandle,
      hash : Bytes,
      token_count : Int32,
      service_id : Int64,
    ) : {Bool, Int64}
      q = db.memo_queries

      # Try to get existing rowid first
      existing = q.get_embedding_rowid?(hash, service_id)
      if existing
        {false, existing}
      else
        rowid = q.insert_embedding_ignore(hash, service_id, token_count, Time.utc.to_unix_ms)
        {true, rowid}
      end
    end

    # Get the rowid of an embedding by hash and service_id.
    def get_rowid(db : DBHandle, hash : Bytes, service_id : Int64) : Int64?
      db.memo_queries.get_embedding_rowid?(hash, service_id)
    end

    # Create chunk reference (or ignore if already exists)
    #
    # Returns chunk id if inserted, or 0 if chunk already existed (was ignored)
    def create_chunk(
      db : DBHandle,
      hash : Bytes,
      source_type : String,
      source_id : Int64,
      offset : Int32?,
      size : Int32,
      pair_id : Int64? = nil,
      parent_id : Int64? = nil,
    ) : Int64
      db.memo_queries.insert_chunk_ignore(hash, source_id, source_type, pair_id, parent_id, offset, size, Time.utc.to_unix_ms)
    end

    # Increment match_count for chunks
    def increment_match_count(db : DBHandle, chunk_ids : Array(Int64))
      return if chunk_ids.empty?
      db.memo_queries.increment_match_count(chunk_ids)
    end

    # Increment read_count for chunks
    def increment_read_count(db : DBHandle, chunk_ids : Array(Int64))
      return if chunk_ids.empty?
      db.memo_queries.increment_read_count(chunk_ids)
    end

    # Serialize embedding to binary blob (Int16 for 50% storage reduction)
    def serialize_embedding(embedding : Array(Float64)) : Bytes
      io = IO::Memory.new
      embedding.each do |value|
        int_val = (value.clamp(-1.0, 1.0) * 32767).round.to_i16
        io.write_bytes(int_val, IO::ByteFormat::LittleEndian)
      end
      io.to_slice
    end

    # Deserialize embedding from binary blob
    def deserialize_embedding(blob : Bytes) : Array(Float64)
      io = IO::Memory.new(blob)
      embedding = [] of Float64
      (blob.size // 2).times do
        int_val = io.read_bytes(Int16, IO::ByteFormat::LittleEndian)
        embedding << int_val.to_f64 / 32767.0
      end
      embedding
    end
  end
end
