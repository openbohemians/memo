module Memo
  module SourceRegistry
    extend self

    # Create a source with no external ID (memo-managed)
    def create(db : DB::Database, source_type : String) : Int64
      db.memo_queries.insert_source(source_type, Time.utc.to_unix_ms)
    end

    # Resolve external ID to internal ID, creating source record if needed
    def resolve(
      db : DB::Database,
      source_type : String,
      external_id : ExternalId,
    ) : Int64
      q = db.memo_queries
      now = Time.utc.to_unix_ms

      case external_id
      when Int64
        internal_id = q.find_source_int(source_type, external_id)
        return internal_id if internal_id
        q.insert_source_int(source_type, external_id, now)
      when Bytes
        internal_id = q.find_source_blob(source_type, external_id)
        return internal_id if internal_id
        q.insert_source_blob(source_type, external_id, now)
      else # String
        ext_str = external_id.as(String)
        internal_id = q.find_source_text(source_type, ext_str)
        return internal_id if internal_id
        q.insert_source_text(source_type, ext_str, now)
      end
    end

    # Get external ID and source_type from internal ID
    def get_external(db : DB::Database, internal_id : Int64) : {String, ExternalId?}?
      row = db.memo_queries.get_source_external(internal_id)
      return nil unless row
      source_type, external_int, external_text, external_blob = row
      external_id : ExternalId? = external_int || external_text || external_blob
      {source_type, external_id}
    end

    # Get internal ID for an external source (doesn't create)
    def get_internal(
      db : DB::Database,
      source_type : String,
      external_id : ExternalId,
    ) : Int64?
      q = db.memo_queries
      case external_id
      when Int64 then q.find_source_int(source_type, external_id)
      when Bytes then q.find_source_blob(source_type, external_id)
      else            q.find_source_text(source_type, external_id.as(String))
      end
    end

    # Get internal ID without source_type filter
    def get_internal_any_type(
      db : DB::Database,
      external_id : ExternalId,
    ) : Int64?
      q = db.memo_queries
      case external_id
      when Int64 then q.find_source_int_any_type(external_id)
      when Bytes then q.find_source_blob_any_type(external_id)
      else            q.find_source_text_any_type(external_id.as(String))
      end
    end

    # Delete a source record
    def delete(
      db : DB::Database,
      source_type : String,
      external_id : ExternalId,
    ) : Bool
      q = db.memo_queries
      rows = case external_id
             when Int64 then q.delete_source_int(source_type, external_id)
             when Bytes then q.delete_source_blob(source_type, external_id)
             else            q.delete_source_text(source_type, external_id.as(String))
             end
      rows > 0
    end

    # Delete source by internal ID
    def delete_by_id(db : DB::Database, internal_id : Int64) : Bool
      db.memo_queries.delete_source_by_id(internal_id) > 0
    end

    # List all sources for a given type
    def list(
      db : DB::Database,
      source_type : String,
      limit : Int32 = 100,
      offset : Int32 = 0,
    ) : Array({Int64, ExternalId?})
      db.memo_queries.list_sources(source_type, limit, offset).map do |internal_id, ext_int, ext_text, ext_blob|
        external_id : ExternalId? = ext_int || ext_text || ext_blob
        {internal_id, external_id}
      end
    end
  end
end
