# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.15.3] - 2026-10-22

### Fixed
- **`memo index -r` handles symlinks, two projects, moved text and deleted files.**
  - It followed symlinks, so a link to a directory outside the tree indexed that directory too, and a
    link back up the tree aborted the run ("Too many levels of symbolic links"). Symlinks inside the
    tree are skipped now, to files and directories alike. The directory you name may still be one.
  - Files were recorded by their path relative to the directory indexed (or, for files named one by
    one, the current directory), so `README.md` in one project and in another were one record, and
    indexing either replaced the other. They're recorded by absolute path now, symlinks resolved. A
    record from an earlier memo is taken over, keeping its id, the next time its file is indexed, and
    isn't embedded again if the file hasn't changed.
  - A run in which one file took up a text another dropped (a paragraph moved between files) failed
    with "Embeddings kept disappearing while indexing", and so did every run after it. Embeddings the
    files drop are now released only once every file in the run has its new chunks.
  - Files deleted from the directory stayed in the index. Indexing a directory now removes the files
    recorded under it that it no longer finds (deleted, or ignored now), listing each with `-`.
- **Specs that index files no longer crash.** The magic shard closes its libmagic handles in an
  `at_exit`, and handlers run last-registered first, so with `spec` required before memo the handles
  were closed before the examples ran. memo's spec helper requires memo first; specs of your own that
  index files through memo need the same order.

### Changed
- `Service#index_files` and `#index_file_list` give their block absolute paths, and `memo index --json`
  lists them. The text output and `memo search` show a file's path relative to the current directory
  when the file is under it. `index_files`'s block also gets `:removed` (`:would_remove` on a dry run),
  and `memo index --json` counts them as `removed`.
- `Files.file_info` takes just the path; the two-argument form is deprecated. `index_file_list`'s `root`
  is used only to find records from earlier versions.

## [0.15.2] - 2026-10-22

### Fixed
- **`use_service` switches everything that belongs to a service.** It kept the previous service's query
  cache, so a query searched before the switch used the old model's vector, and new queries were saved
  under the old service. It now starts a cache for the new service (same sizes), chunks with the new
  service's tokens per byte, and refuses a service whose `max_tokens` is below the chunk size, as opening
  one by name does. It swaps the index while holding the write lock, and if the new index can't be opened
  (another process holds it), it stays on the current service.
- **Opening a service by format and model uses its stored `base_url`.** It took the service's id and
  dimensions but not its endpoint, so a service set up for an OpenAI-compatible API (Azure, a proxy)
  sent its texts to the provider's public endpoint instead. A `base_url` passed to `Service.new` still
  takes precedence, and now does when opening by name or the default service too, where it was ignored.
- **`delete_service` works on PostgreSQL, and leaves other services' data alone.**
  - It didn't delete the service's vocabulary and cached queries, so on PostgreSQL their foreign keys
    refused the delete, and on SQLite they were left behind. Now they go with it.
  - With `force: true`, it deleted every chunk whose text the service had embedded, including chunks
    another service in the database uses. Those stay now.
  - It deleted the index's lock file even while another process held the lock, so a later open could
    lock a new file at the same path while the first process still had the index. Now it takes the lock
    itself before deleting anything (raising `USearchIndex::InUse` if another process has the index
    open), and leaves the lock file in place.
  - It refuses to delete the service the `Service` is using.
- **`Clustering.sequential` works on PostgreSQL.** Its query grouped by source and embedding but ordered
  by chunk offset, which PostgreSQL rejects. Each source is now represented by its first chunk's
  embedding on both databases; on SQLite it was whichever chunk the grouping happened to pick.
- **Removed vectors don't linger in another service's index.** Deleting a text logs its removal for
  every service that embedded it, but only the deleting service's index applied it. With another
  service's index open meanwhile, that index's next save checkpointed past the removal, so the vector
  stayed in its file for good, taking up a nearest-neighbor slot. Saving now applies such removals
  first. Replaying the journal also looked vectors up by id alone, so on SQLite, where a deleted
  embedding's id can be reused, a service could replay another service's vector into its index.
- **memo-arcana chunks a namespace at the mock service's 100 tokens only when it uses mock.** A
  namespace named only by `format` (say `openai`), or by neither `service` nor `format` (the database's
  default service, `openai` in a new one), was taken for mock and chunked at 100 tokens instead of the
  default 2000. Its texts get larger chunks the next time they're indexed with changed text.

## [0.15.1] - 2026-10-22

### Fixed
- **memo-arcana won't start while another one serves `memo:rag`.** A second instance on the same bus
  joined the same address and shared its mailbox, and when either one stopped, the bus dropped the address
  for both, leaving the other running but unreachable. memo-arcana now looks `memo:rag` up in the bus's
  directory, and if it's listed, asks it for help; a reply means another instance is serving, and
  memo-arcana exits with an error. A listing no one answers for, as after a bus restart, doesn't stop it.
- **memo-arcana rejoins the bus when its connection drops.** When the bus restarted, memo-arcana exited
  with status 0 and no message, so systemd's `Restart=on-failure` left it stopped. It now logs the loss
  and rejoins, retrying with waits that grow from 1 to 30 seconds, and checks first that no other
  memo-arcana has taken `memo:rag` meanwhile. A bus it can't reach at startup is retried the same way.

## [0.15.0] - 2026-10-22

### Changed
- **Requires pg ~> 0.31.0, and so crystal-db 0.15** (was pg ~> 0.30.0 on crystal-db 0.14), so memo
  resolves alongside projects on sqlite3 0.24, which needs crystal-db 0.15. Projects that use memo as a
  library move up with it (`shards update pg db sqlite3`). crystal-db 0.15's breaking change is for
  driver authors, and no memo code changed.

## [0.14.3] - 2026-10-22

### Fixed
- **Databases sharing an index directory keep separate index files.** Every PostgreSQL database's index
  went in the same directory under the same name (`memo.<format>--<model>--<dimensions>.usearch`), and
  so did every index in an `index_dir`. A second database open at the same time failed with `InUse`,
  and one opened later could take the other's vectors for its own. Such a file is now named after the
  database's name and a random id memo stores in it (`memo_meta.database_id`), for example
  `wow_dev-3f9a1c2b.openai--text-embedding-3-small--1536.usearch`. An index beside a SQLite file keeps
  its name. The checkpoint now records the database and service too, so a file from elsewhere is
  rebuilt from stored vectors rather than used.
- **Upgrading keeps the index.** A file under the old shared name is adopted by the database whose
  vectors it holds, checked against a sample of its stored vectors, so it isn't rebuilt (a rebuild
  adds about 450 vectors a second at 1536 dimensions). An older memo opening the new files rebuilds
  them.
- **`use_service` and `delete_service` use `index_dir`.** They built the index path without it, so
  `delete_service` could delete another database's index file in the default directory.

## [0.14.2] - 2026-10-22

### Changed
- **memo-arcana takes its namespaces from its config file.** An `open` request registers a namespace the
  config doesn't list only when memo-arcana runs with `MEMO_BUS_OPEN=1`. An `open` for a configured
  namespace still succeeds, so a client that opens its namespace when it connects keeps working once the
  namespace is in `namespaces.yaml`.

### Security
- **A namespace opened over the bus doesn't get the server's API key.** Without an `api_key` in the
  request, it fell back to `MEMO_API_KEY` or `OPENAI_API_KEY`, and its database, which the client names,
  can set the provider's `base_url`, so the key could be sent anywhere. Only the config file's
  namespaces fall back to those keys now.
- **`open` can't redirect a registered namespace.** It replaced the namespace's settings, so the next
  time the namespace opened (after a `close` or a restart) it used the database the request named.
  Opening a registered namespace again now changes nothing, and with another database it's refused. A
  namespace that fails to open is dropped, so a corrected `open` can follow.
- **A search's `limit` is bounded.** USearch allocates room for `limit` results before it searches, so
  `limit: 1000000000` took about 12 GB. The bus caps `limit` at 1000 and refuses one below 1, and memo
  asks USearch for no more results than the index holds. With filters, a large `limit` also overflowed
  in sizing the candidates.
- **memo-arcana redacts database passwords in its startup log and error replies.** The startup log
  printed each namespace's database URL as is, and the redaction missed `?password=` parameters and URLs
  without a user name.

### Fixed
- **Chunking is linear for non-ASCII text.** It indexed the text by character, which rescans a String
  from its start unless it's all ASCII, so a 200,000-character Cyrillic text took 28.6 s (a release
  build) and blocked every other fiber meanwhile. It now takes 13 ms.
- **No chunk exceeds `chunking_max_tokens`.** A sentence too long for the limit, or a text without
  punctuation, stayed one chunk, which a provider rejects on every retry; such a range is now split at
  the last space that fits, or at the limit itself. Combining small chunks also stops at the limit.
- **Indexing a new source id from several fibers or processes at once doesn't fail.** Resolving the id
  looked it up, then inserted it, so on PostgreSQL a concurrent `index` of the same new id could fail
  with a duplicate-key error. The insert now does nothing when the id exists, and the lookup repeats.

## [0.14.1] - 2026-10-22

### Fixed
- **Search filters apply to every result, including sources that share a text.** Since 0.13.0 a text is
  stored and embedded once however many sources have it. The filters (`source_type`, ids, `sql_where`,
  `like`, `match`) picked the matching embeddings, but the results then listed every source with that
  text, including sources the filters exclude. A search for `source_type: "public", limit: 1` could
  return only a private source. Results now hold only chunks that pass the filters, on SQLite and
  PostgreSQL. The fetch also stops at `limit` chunks per embedding, so a text shared by many sources no
  longer loads them all.
- **An id filter that names no source finds nothing.** `source_id`, `pair_id` or `parent_id` that doesn't
  resolve used to be dropped, which widened the search to everything.
- **An older text no longer overwrites a newer one.** A text is embedded outside the write lock. If its
  source was indexed again during that call, the older text was then written over the newer one, and
  it stayed: the queue held no work to repair it. Queue work now completes in the same transaction as
  its write, and only if the queue still holds that text; otherwise nothing is written. `process_queue`
  had the same race with items queued again after its batch was read.
- **Deleted sources stay deleted.** `delete` left the source's queued work behind, so `process_queue`,
  or an embedding already under way, brought the source back. Deleting now cancels the work.
- **Indexing a blank text removes the source's old chunks.** They used to stay searchable while the
  source pointed at the blank text.

### Changed
- **`search` raises `ArgumentError` for filters it can't apply,** instead of ignoring them:
  - `source_id`, `pair_id` or `parent_id` given without `source_type`;
  - `like` or `match` on a service with `store_text: false`.

## [0.14.0] - 2026-10-22

### Changed
- **Requires arcana-core ~> 0.20.0 and arcana-ai ~> 0.6.1** (were ~> 0.16.0 and ~> 0.5.1), so memo
  resolves alongside projects on the current arcana. Projects that use memo as a library move up with
  it (`shards update arcana-core arcana-ai`). memo-arcana talks to the bus through `Arcana::Client` with
  its own listener, so arcana-core 0.17's concurrent `Toolset`/`Service` handlers don't change it; it
  was checked live against arcana 0.36.2. No memo code changed: memo stopped reading the token counts
  arcana-ai 0.6 removes in 0.13.1.

## [0.13.2] - 2026-10-22

### Fixed
- **Opening a service by format and model no longer adds a copy of it.** Opening a listed service whose
  name isn't `<format>/<model>` (`openai`, `voyage`, `mock`) by format and model added a second row named
  `<format>/<model>` and used it, and the next such open raised `more than one row (DB::Error)`. The
  service found is now used as is. A database that already has the copy opens again, on the listed
  (oldest) service; sources indexed in the one session that used the copy need indexing again to be
  found under it. Reported by @datadungeon.

## [0.13.1] - 2026-10-14

### Changed
- **Token counts come from `usage`**, ahead of their removal in arcana-ai 0.6.0 and arcana 0.36.0.
  The arcana provider reads `Embed::Result#usage.input` instead of the deprecated `total_tokens`, and
  the bus provider reads `usage.input` from the embed service's reply (sent since arcana 0.35). A reply
  without `usage` counts 0 tokens, as when a provider reports none. Requires arcana-ai ~> 0.5.1.

## [0.13.0] - 2026-10-11

### Upgrading
- **The first open of an existing database migrates it once**, in one transaction: each distinct text
  moves into the new `memo_contents` table, with sources and chunks pointing at it, and `memo_texts` and
  its full-text index are dropped. Vectors are copied out of the index file into the new `memo_vectors`
  table. Embeddings missing from both the database and the index file are counted in
  `Service#index_recovery.missing`; indexing their sources again restores them. `memo_meta` records the
  schema version, and a database from a newer memo is refused (`Memo::Migration::NewerSchema`).
- **`memo_texts` is gone.** SQL that read it should join `memo_contents`: a source's latest text is
  `memo_contents ct ON ct.id = s.content_id`, and the text a chunk was cut from `ct.id = c.content_id`
  (see "Reading memo's tables" in the README).
- **An index can only be open in one process at a time.** A second open raises
  `Memo::USearchIndex::InUse`, including the memo CLI against a database a running service has open.
- **Every statement inside a transaction must use the transaction's connection**
  (`Memo::Database.transaction` yields it); statements sent to the pool commit on their own.

### Added
- **Content-addressed text storage**: each distinct text is stored once in `memo_contents`, however many
  sources have it, and indexed for full-text search once (on SQLite without a second copy of the text).
  Sources and chunks point at it. With `store_text: false`, memo keeps the text's hash only, so it can
  still tell when a text hasn't changed.
- **Index journal** (`Memo::IndexJournal`): vectors stored in `memo_vectors` (16-bit floats) and every
  index change logged in `memo_index_log`, in the same transaction as the data. Opening an index
  replays only changes after its checkpoint; a missing, corrupt or stale file is rebuilt from stored
  vectors. `Service#index_recovery` reports what was done.
- **Save policy**: the index saves itself once `index_save_changes` (10,000) changes are unsaved, or
  any have been for `index_save_interval` (5 minutes). `Service#save_index_if_due` is cheap to call often;
  `Service#save_index` saves at once. Saves write the file on a separate thread.
- **`Memo::Database.transaction`** for atomic transactions, and `Memo::DBHandle` (pool or connection).
- **`Memo::ArcanaListener`**: memo-arcana's request handling as a class, with specs on a private bus.
- **memo-arcana settings**: `MEMO_MAX_CONCURRENCY` (default 32), `MEMO_MAX_WAITING` (default 8x concurrency),
  `MEMO_SAVE_INTERVAL` (default 60 s). Beyond the waiting limit, requests get an immediate error with
  `"code": "busy"`, which callers can retry.
- **`Memo::Namespaces#use`**: run a block with a namespace's service; closing the namespace waits for it.
- **`Memo::Providers::HTTPPool`**: pooled connections and retries for the OpenAI and Voyage providers.

### Changed
- **Only chunks with no stored embedding go to the embedding API.** A text another source has costs no
  API call, and an edited text sends only its changed chunks. Embeddings are reused only while their
  vector is stored, so one that was lost is embedded again.
- **Finished queue items no longer keep their text.**
- **memo-arcana's `index` reply** for a text already indexed is `"chunks": 0, "unchanged": true`.
- **Dependencies**: embeddings come from [arcana-ai](https://github.com/trans/arcana-ai)
  (`Arcana::AI::Embed`, ~> 0.4) and the bus types from arcana-core ~> 0.16; memo no longer depends
  on arcana itself (the listener specs run on a small relay in `spec/support/bus_relay.cr`). `pg` is
  pinned to ~> 0.30.0 (crystal-db 0.14) instead of following master.
- **Filtered searches search first and filter second**: unfiltered nearest neighbors are checked against
  the filter by id, widening once if too few pass; narrow filters rank their few matches exactly.
  At 20K vectors, a filter matching 90% of rows went from 10.3 ms to 1.2 ms.
- **memo-arcana answers requests concurrently** and ignores reply envelopes instead of answering them.
- **Opening one namespace no longer blocks requests to others**; replay and rebuild yield to other fibers.
- **The persistent query cache checks its size once per 1% of its limit** (and on each instance's first
  write), not on every write.
- **memo's own SQLite connections wait up to 5 s for a lock** (`busy_timeout=5000`) instead of failing at once.
- **SQLite write transactions begin `IMMEDIATE`**, taking the write lock up front where the busy timeout
  applies. A deferred `BEGIN` failed at once ("database is locked") when another process held the lock.

### Fixed
- **Indexing an unchanged text always called the embedding API**: the content-hash check never fired,
  because queueing a text cleared the stored hash. `index` now returns -1 for a source already indexed with
  the same text, `pair_id` and `parent_id`, without calling the API.
- **A source queued again while its previous text was being embedded lost the new text**: the item was
  marked done. It now stays pending and is embedded next.
- **Search results' text came from a queued text before it was embedded**, cut at the old chunks' offsets.
- **`Memo::Database.create` with a PostgreSQL URL ran SQLite's queries.**
- **Transactions weren't atomic**: statements ran on other pool connections and committed one by one,
  so a failure could leave a source unsearchable while `index` reported success.
- **A crash lost every vector added since the last clean shutdown**, and they couldn't be re-added.
- **Bus-routed embeddings (`bus/openai`, `bus/voyage`) hung in memo-arcana** until a 60 s timeout.
- **Indexing slowed with every document**: deleting a full-text row scanned the whole FTS5 table
  (28 ms per document at 150K). Full-text rows are now looked up by id.
- **SQLite inserts could read another connection's `last_insert_rowid`.**
- **USearch rejected a new embedding** whose reused rowid a stale index file still held.
- **Postgres numbered `?` inside quoted strings** in `sql_where` as a parameter, shifting the rest. Quoted
  strings, identifiers, comments and dollar quotes are now skipped. jsonb's `?`, `?|` and `?&` operators
  can't be used in `sql_where` on Postgres; use `jsonb_exists` and friends.

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
