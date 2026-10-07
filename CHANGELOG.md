# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.13.0] - 2026-10-06

### Upgrading
- **The first open of an existing database migrates it once**: vectors are copied out of the
  index file into the new `memo_vectors` table, and SQLite's full-text table is rebuilt so rows
  are keyed by source id (0.3 s for 150K rows). Embeddings missing from both the database and the
  index file are counted in `Service#index_recovery.missing`; indexing their sources again restores them.
- **An index can only be open in one process at a time.** A second open raises
  `Memo::USearchIndex::InUse`, including the memo CLI against a database a running service has open.
- **Every statement inside a transaction must use the transaction's connection**
  (`Memo::Database.transaction` yields it); statements sent to the pool commit on their own.

### Added
- **Index journal** (`Memo::IndexJournal`): vectors stored in `memo_vectors` (16-bit floats) and every
  index change logged in `memo_index_log`, in the same transaction as the data. Opening an index
  replays only changes after its checkpoint; a missing, corrupt or stale file is rebuilt from stored
  vectors. `Service#index_recovery` reports what was done.
- **Save policy**: the index saves itself once `index_save_changes` (10,000) changes are unsaved, or
  any have been for `index_save_interval` (5 minutes). `Service#save_index_if_due` is cheap to call often;
  `Service#save_index` saves at once. Saves write the file on a separate thread.
- **`Memo::Database.transaction`** for atomic transactions, and `Memo::DBHandle` (pool or connection).
- **`Memo::ArcanaListener`**: memo-arcana's request handling as a class, with specs on a private bus.
- **memo-arcana settings**: `MEMO_MAX_CONCURRENCY` (default 32), `MEMO_SAVE_INTERVAL` (default 60 s).
- **`Memo::Providers::HTTPPool`**: pooled connections and retries for the OpenAI and Voyage providers.

### Changed
- **Filtered searches search first and filter second**: unfiltered nearest neighbors are checked against
  the filter by id, widening once if too few pass; narrow filters rank their few matches exactly.
  At 20K vectors, a filter matching 90% of rows went from 10.3 ms to 1.2 ms.
- **memo-arcana answers requests concurrently** and ignores reply envelopes instead of answering them.
- **Opening one namespace no longer blocks requests to others**; replay and rebuild yield to other fibers.
- **The persistent query cache checks its size once per 1% of its limit**, not on every write.

### Fixed
- **Transactions weren't atomic**: statements ran on other pool connections and committed one by one,
  so a failure could leave a source unsearchable while `index` reported success.
- **A crash lost every vector added since the last clean shutdown**, and they couldn't be re-added.
- **Bus-routed embeddings (`bus/openai`, `bus/voyage`) hung in memo-arcana** until a 60 s timeout.
- **Indexing slowed with every document**: deleting a full-text row scanned the whole FTS5 table
  (28 ms per document at 150K; now a flat ~2 ms).
- **SQLite inserts could read another connection's `last_insert_rowid`.**
- **USearch rejected a new embedding** whose reused rowid a stale index file still held.

## [0.8.1] - 2026-02-09

### Added
- **`--like` and `--match` flags for `memo search`** - expose SQL LIKE and FTS5 full-text filtering in the CLI
- **Per-command `--help`** - `memo search --help` now shows command-specific options via Jargon's built-in help

## [0.8.0] - 2026-02-09

### Changed
- **Redesigned `memo index` CLI** - simpler, Unix-y interface
  - `memo index <files>...` indexes specific files (variadic positional args)
  - `memo index -r <dir>` recursively indexes a directory (replaces `memo index dir`)
  - `echo "text" | memo index` indexes text from stdin (replaces `memo index text`)
  - Directories in args require `-r` flag, otherwise error (like `grep -r`)
  - `--dry-run` no longer requires an API key
- **Updated to Jargon 0.15.0** for variadic positional argument support

### Added
- `Memo::Service#index_file_list` - index an explicit list of file paths without directory walking

### Removed
- `memo index text` and `memo index dir` subcommands (replaced by flat `memo index`)

## [0.7.1] - 2026-02-08

### Fixed
- **Embedding API batch size limits** - `index_files_batched` and `embed_and_store_internal` now split texts into `@batch_size` chunks before calling the provider API, fixing `'$.input' is invalid` errors when indexing many files at once

## [0.7.0] - 2026-02-08

### Changed
- **USearch HNSW index** replaces brute-force cosine similarity search
  - O(log n) approximate nearest neighbor via USearch HNSW
  - One `.usearch` index file per service alongside the SQLite database
  - f16 quantization with cosine metric
- **Embedding vectors removed from SQLite** - USearch is now the sole vector store
  - Embeddings table retained as deduplication registry (hash, service_id, token_count)
  - SQLite rowid maps to USearch key (UInt64)
- **Filtered search** uses SQL pre-filtering then USearch `filtered_search`

### Removed
- **Projection system** - replaced entirely by HNSW index
  - Removed `projection.cr`, projection tables, and projection vectors
- Embedding BLOB column from embeddings table

### Breaking
- Requires re-index (embedding storage format changed)
- USearch C library must be built (`scripts/setup.sh` in usearch shard)

## [0.6.0] - 2026-01-26

### Added
- **File indexer** (`memo index dir <path>`)
  - Index all text files in a directory
  - Respects `.gitignore` patterns (via `ignoreme` library)
  - Binary file detection (via `libmagic`)
  - Incremental updates via mtime tracking
  - `--full` flag to force re-index all files
  - `--dry-run` to preview without indexing
- **Content hash skip** - Skip re-indexing when text content unchanged
- **Search output improvements**
  - Show file paths with IDs (e.g., `[F15] src/memo/search.cr`)
  - Display line numbers for code context
  - Positional query argument (`memo search "query"`)

### Changed
- **CLI refactored to subcommands**
  - `memo index text "..."` (was `memo index`)
  - `memo index dir <path>` (was `memo index-files`)
  - `source-id` now optional for `index text`
- **Batched file indexing** - Single API call for all files (~3x faster)
- **Int16 embedding storage** - 50% size reduction (breaking: requires re-index)
- **Default min-score lowered** to 0.3 (was 0.7)

### Fixed
- Always skip `.git` directory when indexing
- Cleaner API error messages (parse JSON, show message only)

## [0.5.1] - 2026-01-24

### Changed
- **Vocabulary now builds incrementally during index**
  - Words are extracted and embedded alongside chunks automatically
  - No need to run `build-vocab` separately
  - Existing word frequencies updated on each index
  - `build-vocab` remains available for full rebuild

### Added
- `--no-vocab` CLI flag to disable vocabulary building during index
- `build_vocab` option in Service initialization (default true)

## [0.5.0] - 2026-01-22

### Added
- **Vocabulary table for word-level semantic similarity**
  - `build-vocab` CLI command extracts unique words from indexed content
  - `like` CLI command finds semantically similar words
  - `build_vocab()`, `like()`, `vocab_stats()`, `clear_vocab()` API methods
  - Stopword filtering, word normalization, frequency tracking
  - Batch embedding for efficient vocabulary building

### Changed
- **CLI refactored to use CLJ library** for argument parsing
  - Replaced custom parser with schema-driven CLJ
  - Added `key:value` and `--key value` syntax (in addition to `key=value`)
  - Nested subcommand support via CLJ's hierarchical CLI feature
  - Reduced CLI code by ~330 lines

### Fixed
- `Input.bool` now correctly handles `false` values (was raising error)

### Removed
- Custom `parser.cr` and `help.cr` (functionality now provided by CLJ)

## [0.4.0] - 2026-01-21

### Added
- **CLI tool** with JSON Schema validation
  - Commands: `index`, `search`, `delete`, `stats`
  - Service management: `service list`, `service use`, `service create`, `service delete`
  - `key=value` argument syntax (`memo search query="test"`)
  - JSON via stdin with `--stdin` flag
  - Human-readable output by default, `--json` for machine output
  - Auto-generated help from schema
  - Environment variable support (`MEMO_API_KEY`, `OPENAI_API_KEY`, `VOYAGE_API_KEY`)
  - Custom API endpoint support via `endpoint` parameter
  - Positional argument support for single-arg commands (`memo service use voyage`)

### Changed
- Service commands now use subcommand pattern (`memo service create` instead of `memo service-create`)
- Chunking rewritten with range-based offset tracking for exact SUBSTR compatibility
- `tokens_per_byte` now updates in-memory config immediately (no restart needed)

### Fixed
- Remove invalid FK constraint from chunks table (embeddings has composite PK)
- `delete()` now removes texts/texts_fts entries (prevents resurrection on reindex)
- Whitespace-only input now returns empty chunks (was incorrectly producing 1 chunk)
- `create_chunk` returns 0 when insert is ignored (accurate insert counts)
- Error on unknown subcommand instead of silently running default
- Schema comments updated to reflect soft reference design

## [0.3.0] - 2026-01-20

### Changed
- Consolidated two database files (embeddings.db + text.db) into single database file
- Removed ATTACH DATABASE complexity - all tables now in one database
- Replaced `data_dir` parameter with `db_path` - specify full path instead of directory

## [0.2.1] - 2026-01-18

### Added
- Adaptive `tokens_per_byte` ratio for chunking - self-calibrates using exponential moving average instead of hardcoded chars/4
- HTTP timeouts for embedding providers (30s connect, 120s read)

### Fixed
- Chunk offsets now track actual positions in source text (enables accurate SUBSTR extraction)
- Embedding provider responses sorted by index to prevent input/output misalignment
- `delete` now returns actual chunk count, not distinct hash count
- `store_embedding` returns false when row already exists (was always true)
- README examples use `format:` instead of non-existent `provider:` parameter

## [0.2.0] - 2025-01-18

### Added
- Voyage AI embedding provider (voyage-3, voyage-3-lite, voyage-code-3)
- Default service support with `use_service` method
- Service CRUD methods (`create_service`, `get_service`, `list_services`, `delete_service`)

### Fixed
- SQLite3 segfault on close when using ATTACH (now uses setup_connection for connection pool compatibility)
- FTS5 MATCH queries failing with "no such column" error
- `index_batch` incorrectly counting documents with empty text

## [0.1.0] - 2025-01-17

### Added
- Initial release
- `Memo::Service` - High-level API for indexing and searching
- OpenAI embedding provider (text-embedding-3-small, text-embedding-3-large)
- Mock provider for testing
- Configurable model and dimensions for embedding providers
- Smart text chunking with configurable parameters
- Cosine similarity search with filtering (source_type, source_id, pair_id, parent_id)
- Content deduplication via SHA256 hashing
- Service tracking to ensure compatible vector spaces
- Usage tracking (match_count, read_count)
- RRF (Reciprocal Rank Fusion) for hybrid search
- ATTACH support for cross-database queries
- **Embed queue** for background processing with retry support
  - `enqueue`, `enqueue_batch` - Add items to queue
  - `process_queue`, `process_queue_async` - Process queued items
  - `queue_stats` - Get queue status counts
  - `clear_queue`, `clear_completed_queue` - Queue management
- **Reindex** support for re-embedding existing content
  - `reindex(source_type)` - Re-embed from stored text
  - `reindex(source_type, &block)` - Re-embed with custom text provider
- All indexing routes through queue for automatic retry on failures
