module Memo
  module Dialect
    class SQLite < Base
      def insert_returning_id(db : DBHandle, sql : String, *args) : Int64
        db.exec(sql, *args).last_insert_id
      end

      def insert_or_ignore_sql(table : String, columns : String, placeholders : String) : String
        "INSERT OR IGNORE INTO #{table} (#{columns}) VALUES (#{placeholders})"
      end

      def upsert_sql(
        table : String,
        columns : String,
        placeholders : String,
        conflict_columns : String,
        update_columns : Array(String),
      ) : String
        "INSERT OR REPLACE INTO #{table} (#{columns}) VALUES (#{placeholders})"
      end

      def embedding_rowid_column : String
        "rowid"
      end

      SCHEMA_SQL = {{ read_file("#{__DIR__}/../../../db/schema/memo_schema.sql") }}

      def schema_statements : Array(String)
        statements = [] of String
        trigger = nil.as(String?)
        SCHEMA_SQL.split(";").each do |part|
          # A trigger's body has statements of its own: keep its parts
          # together until its END
          if body = trigger
            part = "#{body};#{part}"
            trigger = nil
          end
          statement = part.strip
          next if statement.lines.all? { |line| line.strip.empty? || line.strip.starts_with?("--") }
          if statement.matches?(/^CREATE TRIGGER/im) && !statement.matches?(/\bEND$/i)
            trigger = part
            next
          end
          statements << statement
        end
        statements
      end

      def db_file_path(db : DB::Database) : String?
        db.query_one?(
          "SELECT file FROM pragma_database_list WHERE name = 'main'",
          as: String
        )
      end

      # memo_contents_fts is an external-content table: rows are keyed by
      # the content's id, and MATCH looks them up without a second copy
      def fts_join_sql : String
        "JOIN memo_contents_fts ON memo_contents_fts.rowid = c.content_id"
      end

      def fts_where_sql : String
        "memo_contents_fts MATCH ?"
      end

      def table_exists?(db : DBHandle, table : String) : Bool
        !db.query_one?("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", table, as: Int32).nil?
      end

      def column_exists?(db : DBHandle, table : String, column : String) : Bool
        !db.query_one?("SELECT 1 FROM pragma_table_info(?) WHERE name = ?", table, column, as: Int32).nil?
      end

      # Databases from before 0.13: add content_id to memo_sources and
      # memo_chunks, which the schema's indexes need. The transaction takes
      # the write lock first (BEGIN IMMEDIATE), so a second process opening
      # the database waits, then finds the columns there.
      def prepare(db : DB::Database) : Nil
        return unless CONTENT_TABLES.any? { |table| lacks_content_id?(db, table) }
        Memo::Database.transaction(db) do |cnn|
          CONTENT_TABLES.each do |table|
            next unless lacks_content_id?(cnn, table)
            cnn.exec("ALTER TABLE #{table} ADD COLUMN content_id INTEGER REFERENCES memo_contents(id)")
          end
        end
      end

      # Tables that point at memo_contents
      private CONTENT_TABLES = {"memo_sources", "memo_chunks"}

      private def lacks_content_id?(db : DBHandle, table : String) : Bool
        table_exists?(db, table) && !column_exists?(db, table, "content_id")
      end

      def drop_legacy_texts(db : DBHandle) : Nil
        db.exec("DROP TABLE IF EXISTS memo_texts_fts")
        db.exec("DROP TABLE IF EXISTS memo_texts")
        db.exec("DELETE FROM memo_meta WHERE key = 'fts_rowid_is_source_id'")
      end

      # BEGIN IMMEDIATE already holds the write lock
      def lock_for_migration(db : DB::Connection) : Nil
      end
    end
  end
end
