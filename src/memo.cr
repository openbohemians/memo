require "db"
require "sqlite3"
require "digest/sha256"
require "set"
require "usearch"

# Extend DB::Database to carry dialect and queries
# This avoids global state - each db connection knows its config
class DB::Database
  property memo_dialect : Memo::Dialect::Base { Memo::Dialect::SQLite.new }
  property memo_queries : Memo::Queries { Memo::Queries::SQLite.new(self) }
end

# A connection carries the same config while it runs a transaction
# (copied from its database by Memo::Database.transaction).
class DB::Connection
  property memo_dialect : Memo::Dialect::Base { Memo::Dialect::SQLite.new }
  property memo_queries : Memo::Queries { Memo::Queries::SQLite.new(self) }
end

module Memo
  # Where statements run: the connection pool, or the single connection
  # holding an open transaction.
  alias DBHandle = DB::Database | DB::Connection
end

require "./memo/types"
require "./memo/config"
require "./memo/dialect"
require "./memo/database"
require "./memo/chunking"
require "./memo/providers/base"
require "./memo/providers/openai"
require "./memo/providers/voyage"
require "./memo/providers/mock"
require "./memo/providers/arcana"
require "./memo/providers/bus"
require "./memo/providers/registry"
require "./memo/source_registry"
require "./memo/storage"
require "./memo/usearch_index"
require "./memo/rrf"
require "./memo/search"
require "./memo/vocab"
require "./memo/files"
require "./memo/clustering"
require "./memo/service_provider"
require "./memo/queries/base"
require "./memo/queries/sqlite"
require "./memo/query_cache"
require "./memo/service"

# Memo - Semantic search and vector storage library
#
# A focused library for chunking, embedding, and searching text using
# vector similarity. Designed to be embedded in applications that need
# semantic search capabilities.
#
# ## Quick Start
#
# ```
# require "memo"
#
# # Initialize database
# db = DB.open("sqlite3://app.db")
# Memo::Database.load_schema(db)
#
# # Create service (handles embeddings internally)
# memo = Memo::Service.new(
#   db: db,
#   provider: "openai",
#   api_key: ENV["OPENAI_API_KEY"]
# )
#
# # Index a document
# memo.index(
#   source_type: "document",
#   source_id: 42,
#   text: "Your document text..."
# )
#
# # Search
# results = memo.search(query: "search query", limit: 10)
# ```
#
# ## API
#
# The primary API is `Memo::Service` which provides:
# - `index()` - Index documents with automatic chunking and embedding
# - `search()` - Search with automatic query embedding
# - `mark_as_read()` - Track chunk usage
#
# Internal modules (Storage, Search, Chunking, RRF) remain accessible
# for advanced use cases but Service is the recommended entry point.
module Memo
  VERSION = "0.12.1"
end
