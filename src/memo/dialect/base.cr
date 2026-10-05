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

      # Get the database file path from a connection, if applicable.
      #
      # SQLite: reads pragma_database_list
      # PostgreSQL: returns nil (no local file)
      abstract def db_file_path(db : DB::Database) : String?

      # Insert or update FTS index for a source.
      abstract def fts_upsert(db : DBHandle, source_id : Int64, content : String)

      # Delete FTS index entry for a source.
      abstract def fts_delete(db : DBHandle, source_id : Int64)

      # Build FTS JOIN clause for search queries.
      abstract def fts_join_sql : String

      # Build FTS WHERE clause for match queries.
      abstract def fts_where_sql : String
    end
  end
end
