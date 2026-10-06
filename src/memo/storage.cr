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

    # Encode a vector for memo_vectors as little-endian IEEE half floats.
    #
    # That is the precision the USearch index keeps (f16 quantization), so an
    # index rebuilt from stored vectors matches one built from the provider's.
    # Unlike serialize_embedding, values outside -1..1 aren't clamped.
    def encode_vector(vector : Array(Float64)) : Bytes
      bytes = Bytes.new(vector.size * 2)
      vector.each_with_index do |value, i|
        IO::ByteFormat::LittleEndian.encode(f32_to_f16(value.to_f32), bytes[i * 2, 2])
      end
      bytes
    end

    # Decode a vector stored by encode_vector.
    def decode_vector(blob : Bytes) : Array(Float64)
      Array.new(blob.size // 2) do |i|
        f16_to_f32(IO::ByteFormat::LittleEndian.decode(UInt16, blob[i * 2, 2])).to_f64
      end
    end

    # Round a Float32 to the nearest IEEE half float (ties to even).
    private def f32_to_f16(value : Float32) : UInt16
      bits = value.unsafe_as(UInt32)
      sign = (bits >> 16) & 0x8000_u32
      exponent = ((bits >> 23) & 0xff_u32).to_i32
      mantissa = bits & 0x7fffff_u32

      if exponent == 0xff # infinity or NaN
        return (sign | 0x7c00_u32 | (mantissa == 0 ? 0_u32 : 0x200_u32)).to_u16
      end

      half_exponent = exponent - 127 + 15
      return (sign | 0x7c00_u32).to_u16 if half_exponent >= 0x1f # too large: infinity

      if half_exponent <= 0 # subnormal half, or too small: zero
        return sign.to_u16 if half_exponent < -10
        mantissa |= 0x800000_u32
        shift = 14 - half_exponent
        half = mantissa >> shift
        remainder = mantissa & ((1_u32 << shift) - 1)
        halfway = 1_u32 << (shift - 1)
        half += 1 if remainder > halfway || (remainder == halfway && half.odd?)
        return (sign | half).to_u16
      end

      half = (half_exponent.to_u32 << 10) | (mantissa >> 13)
      remainder = mantissa & 0x1fff_u32
      # Rounding up can carry into the exponent, which is still correct.
      half += 1 if remainder > 0x1000 || (remainder == 0x1000 && half.odd?)
      (sign | half).to_u16
    end

    private def f16_to_f32(half : UInt16) : Float32
      sign = (half.to_u32 & 0x8000_u32) << 16
      exponent = (half.to_u32 >> 10) & 0x1f_u32
      mantissa = half.to_u32 & 0x3ff_u32

      bits = if exponent == 0x1f # infinity or NaN
               sign | 0x7f800000_u32 | (mantissa << 13)
             elsif exponent != 0
               sign | ((exponent + 127 - 15) << 23) | (mantissa << 13)
             elsif mantissa == 0
               sign
             else # subnormal half: normalize
               e = 127 - 15 + 1
               until mantissa & 0x400_u32 != 0
                 mantissa <<= 1
                 e -= 1
               end
               sign | (e.to_u32 << 23) | ((mantissa & 0x3ff_u32) << 13)
             end
      bits.unsafe_as(Float32)
    end
  end
end
