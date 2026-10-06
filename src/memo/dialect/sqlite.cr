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
        statements = SCHEMA_SQL.split(";").map(&.strip).reject(&.empty?)
        statements.reject do |statement|
          statement.lines.all? { |line| line.strip.empty? || line.strip.starts_with?("--") }
        end
      end

      def db_file_path(db : DB::Database) : String?
        db.query_one?(
          "SELECT file FROM pragma_database_list WHERE name = 'main'",
          as: String
        )
      end

      # FTS rows are keyed by rowid = source_id. An FTS5 table can only look
      # rows up by rowid (or MATCH); filtering on its source_id column scans
      # the whole table, which made each indexed document slower than the
      # last (9 ms per lookup at 150K documents).
      def fts_upsert(db : DBHandle, source_id : Int64, content : String)
        db.exec("DELETE FROM memo_texts_fts WHERE rowid = ?", source_id)
        db.exec("INSERT INTO memo_texts_fts (rowid, source_id, content) VALUES (?, ?, ?)", source_id, source_id, content)
      end

      def fts_delete(db : DBHandle, source_id : Int64)
        db.exec("DELETE FROM memo_texts_fts WHERE rowid = ?", source_id)
      end

      def fts_join_sql : String
        "JOIN memo_texts_fts ON memo_texts_fts.rowid = c.source_id"
      end

      def migrate(db : DB::Database) : Nil
        # Databases from before FTS rows were keyed by source_id: rebuild
        # the FTS table from memo_texts once.
        return if db.query_one?("SELECT 1 FROM memo_meta WHERE key = 'fts_rowid_is_source_id'", as: Int32)

        Memo::Database.transaction(db) do |cnn|
          cnn.exec("DELETE FROM memo_texts_fts")
          cnn.exec("INSERT INTO memo_texts_fts (rowid, source_id, content) SELECT source_id, source_id, content FROM memo_texts")
          cnn.exec("INSERT INTO memo_meta (key, value) VALUES ('fts_rowid_is_source_id', '1')")
        end
      end

      def fts_where_sql : String
        "memo_texts_fts MATCH ?"
      end
    end
  end
end
