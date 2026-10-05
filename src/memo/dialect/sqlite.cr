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

      def fts_upsert(db : DBHandle, source_id : Int64, content : String)
        db.exec("DELETE FROM memo_texts_fts WHERE source_id = ?", source_id)
        db.exec("INSERT INTO memo_texts_fts (source_id, content) VALUES (?, ?)", source_id, content)
      end

      def fts_delete(db : DBHandle, source_id : Int64)
        db.exec("DELETE FROM memo_texts_fts WHERE source_id = ?", source_id)
      end

      def fts_join_sql : String
        "JOIN memo_texts_fts ON c.source_id = memo_texts_fts.source_id"
      end

      def fts_where_sql : String
        "memo_texts_fts MATCH ?"
      end
    end
  end
end
