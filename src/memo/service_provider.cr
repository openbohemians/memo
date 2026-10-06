module Memo
  module ServiceProvider
    struct Info
      getter id : Int64
      getter name : String
      getter format : String
      getter base_url : String?
      getter model : String
      getter dimensions : Int32
      getter max_tokens : Int32
      getter tokens_per_byte : Float64
      getter? is_default : Bool
      getter created_at : Time

      def initialize(
        @id, @name, @format, @base_url, @model, @dimensions,
        @max_tokens, @tokens_per_byte, @is_default, @created_at,
      )
      end
    end

    struct Stats
      getter embeddings : Int64
      getter chunks : Int64

      def initialize(@embeddings, @chunks)
      end

      def empty? : Bool
        @embeddings == 0 && @chunks == 0
      end
    end

    extend self

    def create(
      db : DB::Database,
      name : String,
      format : String,
      model : String,
      dimensions : Int32,
      max_tokens : Int32,
      base_url : String? = nil,
      is_default : Bool = false,
    ) : Info
      q = db.memo_queries
      existing = q.get_service_info_by_name(name)
      raise ArgumentError.new("Service '#{name}' already exists") if existing

      q.clear_default_service if is_default

      now = Time.utc
      id = q.insert_service_full(name, format, base_url, model, dimensions, max_tokens, is_default ? 1 : 0, now.to_unix_ms)
      Info.new(id: id, name: name, format: format, base_url: base_url, model: model,
        dimensions: dimensions, max_tokens: max_tokens, tokens_per_byte: 0.25,
        is_default: is_default, created_at: now)
    end

    def get(db : DB::Database, id : Int64) : Info?
      db.memo_queries.get_service_info(id)
    end

    def get_by_name(db : DB::Database, name : String) : Info?
      db.memo_queries.get_service_info_by_name(name)
    end

    def get_default(db : DB::Database) : Info?
      db.memo_queries.get_default_service
    end

    def set_default(db : DB::Database, name : String) : Bool
      q = db.memo_queries
      svc = q.get_service_info_by_name(name)
      return false unless svc

      Memo::Database.transaction(db) do |cnn|
        tq = cnn.memo_queries
        tq.clear_default_service
        tq.set_default_service(svc.id)
      end
      true
    end

    def list(db : DB::Database) : Array(Info)
      db.memo_queries.list_services
    end

    def list_by_format(db : DB::Database, format : String) : Array(Info)
      db.memo_queries.list_services_by_format(format)
    end

    def update(
      db : DB::Database,
      id : Int64,
      base_url : String? = nil,
      max_tokens : Int32? = nil,
    ) : Info?
      q = db.memo_queries
      updates = [] of String
      params = [] of DB::Any

      if base_url
        updates << "base_url = ?"
        params << base_url
      end
      if max_tokens
        updates << "max_tokens = ?"
        params << max_tokens
      end

      return q.get_service_info(id) if updates.empty?

      q.update_service(id, updates, params)
      q.get_service_info(id)
    end

    def delete(db : DB::Database, id : Int64, force : Bool = false) : Bool
      q = db.memo_queries
      return false unless q.get_service_info(id)

      s = stats(db, id)
      if !s.empty? && !force
        raise ArgumentError.new(
          "Cannot delete service #{id}: has #{s.embeddings} embeddings and #{s.chunks} chunks. " \
          "Use force: true to delete all associated data."
        )
      end

      Memo::Database.transaction(db) do |cnn|
        tq = cnn.memo_queries
        if force && !s.empty?
          hashes = tq.get_embedding_hashes_for_service(id)
          hashes.each { |hash| tq.delete_chunks_by_hash(hash) }
          tq.delete_embeddings_by_service(id)
        end
        tq.delete_index_data(id)
        tq.delete_service(id)
      end
      true
    end

    def stats(db : DB::Database, id : Int64) : Stats
      q = db.memo_queries
      Stats.new(q.count_embeddings_for_service(id), q.count_chunks_for_service(id))
    end

    def exists?(db : DB::Database, id : Int64) : Bool
      db.memo_queries.service_exists?(id)
    end

    def count(db : DB::Database) : Int64
      db.memo_queries.count_services
    end
  end
end
