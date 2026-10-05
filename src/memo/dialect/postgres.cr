module Memo
  module Dialect
    class Postgres < Base
      def insert_returning_id(db : DB::Database, sql : String, *args) : Int64
        db.scalar("#{sql} RETURNING id", *args).as(Int64)
      end

      def insert_or_ignore_sql(table : String, columns : String, placeholders : String) : String
        "INSERT INTO #{table} (#{columns}) VALUES (#{placeholders}) ON CONFLICT DO NOTHING"
      end

      def upsert_sql(
        table : String,
        columns : String,
        placeholders : String,
        conflict_columns : String,
        update_columns : Array(String),
      ) : String
        updates = update_columns.map { |col| "#{col} = EXCLUDED.#{col}" }.join(", ")
        "INSERT INTO #{table} (#{columns}) VALUES (#{placeholders}) " \
        "ON CONFLICT (#{conflict_columns}) DO UPDATE SET #{updates}"
      end

      def embedding_rowid_column : String
        "eid"
      end

      SCHEMA_SQL = {{ read_file("#{__DIR__}/../../../db/schema/memo_schema_pg.sql") }}

      def schema_statements : Array(String)
        # Smart split: don't split on ';' inside $$ blocks
        split_statements(SCHEMA_SQL)
      end

      def db_file_path(db : DB::Database) : String?
        nil
      end

      def fts_upsert(db : DB::Database, source_id : Int64, content : String)
        # No-op: the memo_trg_texts_tsv trigger auto-populates content_tsv
      end

      def fts_delete(db : DB::Database, source_id : Int64)
        # No-op: content_tsv is a column on memo_texts, deleted with the row
      end

      def fts_join_sql : String
        "JOIN memo_texts fts_t ON c.source_id = fts_t.source_id"
      end

      def fts_where_sql : String
        "fts_t.content_tsv @@ plainto_tsquery('english', ?)"
      end

      # Split SQL into statements, respecting $$ delimited blocks
      private def split_statements(sql : String) : Array(String)
        statements = [] of String
        current = String::Builder.new
        in_dollar_block = false
        i = 0

        while i < sql.size
          if sql[i] == '$' && i + 1 < sql.size && sql[i + 1] == '$'
            current << "$$"
            in_dollar_block = !in_dollar_block
            i += 2
          elsif sql[i] == ';' && !in_dollar_block
            stmt = current.to_s.strip
            unless stmt.empty? || stmt.lines.all? { |line| line.strip.empty? || line.strip.starts_with?("--") }
              statements << stmt
            end
            current = String::Builder.new
            i += 1
          else
            current << sql[i]
            i += 1
          end
        end

        stmt = current.to_s.strip
        unless stmt.empty? || stmt.lines.all? { |line| line.strip.empty? || line.strip.starts_with?("--") }
          statements << stmt
        end

        statements
      end
    end
  end
end
