module Memo
  # Converts a database written by an earlier version of memo, once. The
  # version a database is at is kept in memo_meta.
  module Migration
    extend self

    # 1 (memo 0.13): each distinct text is stored once, in memo_contents,
    # and sources and chunks point at it. Databases from before have no
    # version.
    SCHEMA_VERSION = 1

    class NewerSchema < Exception
    end

    # Runs in one transaction, so a failure leaves the database as it was.
    # A second process opening the database meanwhile waits for it.
    def run(db : DB::Database) : Nil
      return if current?(db)
      Memo::Database.transaction(db) do |cnn|
        cnn.memo_dialect.lock_for_migration(cnn)
        next if current?(cnn) # another process migrated it first

        contents_from_texts(cnn) if cnn.memo_dialect.table_exists?(cnn, "memo_texts")
        cnn.memo_queries.clear_completed_queue_texts
        cnn.memo_queries.set_meta("schema_version", SCHEMA_VERSION.to_s)
      end
    end

    def version(db : DBHandle) : Int32
      db.memo_queries.get_meta("schema_version").try(&.to_i?) || 0
    end

    private def current?(db : DBHandle) : Bool
      found = version(db)
      if found > SCHEMA_VERSION
        raise NewerSchema.new("This database has memo schema version #{found}, " \
                              "newer than this memo supports (#{SCHEMA_VERSION}). Upgrade memo.")
      end
      found == SCHEMA_VERSION
    end

    # memo_texts kept a copy of the text per source. Store each distinct
    # text once and point its sources at it, and their chunks when the text
    # is the one they were cut from: memo_texts had the hash only then (a
    # queued text had none until embedded, and the queue still holds it).
    private def contents_from_texts(cnn : DB::Connection) : Nil
      q = cnn.memo_queries
      now = Time.utc.to_unix_ms
      after = 0_i64
      loop do
        rows = q.legacy_texts_after(after, 1000)
        break if rows.empty?
        rows.each do |source_id, content, embedded_hash|
          content_id = q.upsert_content(Storage.compute_hash(content), content, now)
          q.set_source_content(source_id, content_id)
          q.set_chunks_content(source_id, content_id) if embedded_hash
        end
        after = rows.last[0]
      end
      cnn.memo_dialect.drop_legacy_texts(cnn)
    end
  end
end
