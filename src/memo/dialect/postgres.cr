module Memo
  module Dialect
    class Postgres < Base
      def insert_returning_id(db : DBHandle, sql : String, *args) : Int64
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

      def fts_join_sql : String
        "JOIN memo_contents fts_t ON fts_t.id = c.content_id"
      end

      def fts_where_sql : String
        "fts_t.content_tsv @@ plainto_tsquery('english', ?)"
      end

      def table_exists?(db : DBHandle, table : String) : Bool
        db.scalar("SELECT to_regclass($1) IS NOT NULL", table).as(Bool)
      end

      def drop_legacy_texts(db : DBHandle) : Nil
        db.exec("DROP TABLE IF EXISTS memo_texts")
        db.exec("DROP FUNCTION IF EXISTS memo_texts_tsv_trigger()")
      end

      # Two processes opening the database at once would otherwise both
      # migrate it. The lock is released when the transaction ends.
      def lock_for_migration(db : DB::Connection) : Nil
        db.exec("SELECT pg_advisory_xact_lock(#{MIGRATION_LOCK})")
      end

      # Any constant shared by every memo process ("memo" in ASCII)
      MIGRATION_LOCK = 0x6d656d6f_i64

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
