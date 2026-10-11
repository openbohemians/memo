module Memo
  module Dialect
    # Abstract interface for SQL dialect differences between SQLite and PostgreSQL.
    #
    # Most SQL in Memo is cross-database compatible. This module only abstracts
    # the patterns that differ:
    #
    # - Insert-and-return-ID (last_insert_rowid vs RETURNING)
    # - Conflict handling (INSERT OR IGNORE, INSERT OR REPLACE)
    # - Implicit rowid (SQLite) vs explicit column (PostgreSQL)
    # - FTS5 (SQLite) vs tsvector/GIN (PostgreSQL)
    # - Schema DDL (AUTOINCREMENT, BLOB, REAL types)
    # - DB path discovery (pragma vs connection string)
    abstract class Base
      # Execute an INSERT and return the generated ID.
      abstract def insert_returning_id(db : DBHandle, sql : String, *args) : Int64

      # Build INSERT OR IGNORE SQL.
      abstract def insert_or_ignore_sql(table : String, columns : String, placeholders : String) : String

      # Build upsert SQL (INSERT OR REPLACE equivalent).
      abstract def upsert_sql(
        table : String,
        columns : String,
        placeholders : String,
        conflict_columns : String,
        update_columns : Array(String),
      ) : String

      # The column name for embedding row identity used as USearch key.
      #
      # SQLite: "rowid" (implicit)
      # PostgreSQL: "eid" (explicit column)
      abstract def embedding_rowid_column : String

      # Get schema DDL statements.
      abstract def schema_statements : Array(String)

      # Bring existing tables up to date before the schema runs, where its
      # statements depend on columns older databases lack.
      def prepare(db : DB::Database) : Nil
      end

      abstract def table_exists?(db : DBHandle, table : String) : Bool

      # Drop the tables content-addressed storage replaced (memo_texts and
      # its full-text index).
      abstract def drop_legacy_texts(db : DBHandle) : Nil

      # Inside a migration's transaction: keep other processes from
      # migrating the same database at the same time.
      abstract def lock_for_migration(db : DB::Connection) : Nil

      # Get the database file path from a connection, if applicable.
      #
      # SQLite: reads pragma_database_list
      # PostgreSQL: returns nil (no local file)
      abstract def db_file_path(db : DB::Database) : String?

      # Build FTS JOIN clause for search queries (joining a chunk's text).
      abstract def fts_join_sql : String

      # Build FTS WHERE clause for match queries.
      abstract def fts_where_sql : String
    end
  end
end
