# Memo

Semantic search and vector storage library for Crystal.

## Features

- **CLI tool** - Index, search, and manage from the command line
- **Text chunking** - Smart segmentation into optimal-sized pieces
- **Embedding storage** - Deduplication by content hash
- **HNSW search** - Fast approximate nearest neighbor via USearch
- **Text storage** - Optional persistent text with LIKE and FTS5 full-text search
- **Crash-safe index** - Vectors and index changes are journaled in the database; a crash or lost index
  file is recovered without calling the embedding API again
- **SQLite or PostgreSQL** - For metadata, text and stored vectors
- **Bus service** - `memo-arcana` serves memo over the [Arcana](https://github.com/trans/arcana) agent bus,
  with any number of isolated namespaces

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  memo:
    github: openbohemians/memo
```

Then run `shards install`.

## CLI

Build the CLI:

```bash
shards build
```

### Environment Variables

The CLI reads API keys from environment variables:

```bash
export MEMO_API_KEY=sk-...      # Primary
export OPENAI_API_KEY=sk-...    # Fallback
export VOYAGE_API_KEY=pa-...    # Fallback
```

### Global Options

```
-d, --db=PATH       Database path (default: memo.db)
-s, --service=NAME  Service name (default: openai)
-k, --api-key=KEY   API key (overrides environment variables)
-j, --json          Output as JSON (default: human-readable)
    --no-vocab      Disable vocabulary building during index
-h, --help          Show help
-v, --version       Show version
```

### Commands

**Index files:**

```bash
memo index file1.cr file2.cr       # Index specific files
memo index src/*.cr                # Index files matching a glob
memo index -r .                    # Recursively index current directory
memo index -r /path/to/project     # Recursively index specific path
memo index -r . --dry-run          # Preview without indexing
memo index -r . --full             # Force re-index all files
```

**Index text from stdin:**

```bash
echo "Your document text" | memo index
echo "Document" | memo index --source-type=article --source-id=1
```

**Search:**

```bash
memo search "semantic search"
memo search "query" --limit=5 --min-score=0.5
memo search "query" --like "%pattern%"       # Filter by LIKE pattern
memo search "query" --match "cats OR dogs"   # Filter by FTS5 full-text search
```

**Delete:**

```bash
memo delete source-id=1
```

**Stats:**

```bash
memo stats
```

**Find similar words:**

Vocabulary is built automatically during indexing. Just use `terms`:

```bash
memo terms "database"
# 0.70  data
# 0.70  databases
# 0.57  sqlite
```

**Rebuild vocabulary (optional):**

```bash
memo build-vocab  # Full rebuild from all indexed texts
```

### Service Management

List available services:

```bash
memo service list
memo service           # 'list' is the default
```

Set default service:

```bash
memo service use voyage
```

Create custom service:

```bash
memo service create name=my-openai format=openai model=text-embedding-3-large dimensions=1024 max-tokens=8191
```

Delete service:

```bash
memo service delete my-openai
memo service delete my-openai force=true  # if service has embeddings
```

### JSON Input

Commands accept JSON via stdin with `--stdin`:

```bash
echo '{"query":"semantic search","limit":5}' | memo search --stdin
```

### JSON Output

Use `--json` for machine-readable output:

```bash
memo --json search query="test" | jq '.[] | select(.score > 0.8)'
```

## Quick Start (Library)

```crystal
require "memo"

# Create service with database path
memo = Memo::Service.new(
  db_path: "/var/data/memo.db",
  format: "openai",
  api_key: ENV["OPENAI_API_KEY"]
)

# Index a document
memo.index(
  source_type: "article",
  source_id: 42_i64,
  text: "Your document text here..."
)

# Search
results = memo.search(query: "search query", limit: 10)
results.each do |r|
  puts "#{r.source_type}:#{r.source_id} (score: #{r.score})"
end

# Clean up
memo.close
```

## API

### `Memo::Service`

The main API. Handles database lifecycle, chunking, and embeddings.

#### Initialization

```crystal
memo = Memo::Service.new(
  db_path: "/var/data/memo.db",  # Path to database file
  format: "openai",              # API format ("openai", "voyage", "mock")
  api_key: "sk-...",             # API key for provider
  model: nil,                    # Optional: override default model
  dimensions: nil,               # Optional: embedding dimensions (provider default)
  store_text: true,              # Optional: enable text storage (default true)
  chunking_max_tokens: 2000      # Optional: max tokens per chunk
)
```

For smaller embeddings (faster search, less storage):

```crystal
memo = Memo::Service.new(
  db_path: "/var/data/memo.db",
  format: "openai",
  api_key: key,
  model: "text-embedding-3-large",
  dimensions: 1024  # Reduced from 3072 default
)
```

#### Indexing

```crystal
# Index single document
memo.index(
  source_type: "article",
  source_id: 123_i64,
  text: "Long text to index...",
  pair_id: nil,      # Optional: related source
  parent_id: nil     # Optional: hierarchical parent
)

# Index with Document struct
doc = Memo::Document.new(
  source_type: "article",
  source_id: 123_i64,
  text: "Document text..."
)
memo.index(doc)

# Batch indexing (more efficient)
docs = [
  Memo::Document.new(source_type: "article", source_id: 1_i64, text: "First..."),
  Memo::Document.new(source_type: "article", source_id: 2_i64, text: "Second..."),
]
memo.index_batch(docs)
```

#### Search

```crystal
results = memo.search(
  query: "search query",
  limit: 10,
  min_score: 0.7,
  source_type: nil,    # Optional: filter by type
  source_id: nil,      # Optional: filter by ID
  pair_id: nil,        # Optional: filter by pair
  parent_id: nil,      # Optional: filter by parent
  like: nil,           # Optional: LIKE pattern(s) for text filtering
  match: nil,          # Optional: FTS5 full-text search query
  sql_where: nil,      # Optional: raw SQL WHERE clause
  include_text: false  # Optional: include text content in results
)
```

#### Text Filtering

When text storage is enabled, you can filter by text content:

```crystal
# LIKE pattern (single)
results = memo.search(query: "cats", like: "%kitten%")

# LIKE patterns (AND logic)
results = memo.search(query: "pets", like: ["%cat%", "%dog%"])

# FTS5 full-text search
results = memo.search(query: "animals", match: "cats OR dogs")
results = memo.search(query: "animals", match: "quick brown*")  # prefix
results = memo.search(query: "animals", match: '"exact phrase"')

# Include text in results
results = memo.search(query: "cats", include_text: true)
results.each { |r| puts r.text }
```

#### Queue Operations

All indexing goes through an embed queue with automatic retry support:

```crystal
# Check queue status
stats = memo.queue_stats
puts "Pending: #{stats.pending}, Failed: #{stats.failed}"

# Process any pending/failed items in queue
memo.process_queue

# Process queue in background (non-blocking)
memo.process_queue_async

# Re-index all documents of a type (requires text storage)
memo.reindex("article")

# Re-index with custom text provider (no text storage needed)
memo.reindex("article") do |source_id|
  Article.find(source_id).content  # Your app provides text
end

# Clear completed items from queue
memo.clear_completed_queue

# Clear entire queue (pending, failed, completed)
memo.clear_queue
```

#### Vocabulary (Word-Level Similarity)

Build a vocabulary from indexed content for word-level semantic search:

```crystal
# Build vocabulary from all indexed texts
memo.build_vocab  # => 1523 (words stored)

# Find words similar to a query
results = memo.like("database")
results.each do |r|
  puts "#{r.word}: #{r.score} (freq: #{r.frequency})"
end
# data: 0.70 (freq: 5)
# databases: 0.70 (freq: 2)
# sqlite: 0.57 (freq: 1)

# Get vocabulary size
memo.vocab_stats  # => 1523

# Clear vocabulary
memo.clear_vocab
```

#### Other Operations

```crystal
# Get statistics
stats = memo.stats
puts "Embeddings: #{stats.embeddings}, Chunks: #{stats.chunks}, Sources: #{stats.sources}"

# Delete by source
memo.delete(source_id: 123_i64)
memo.delete(source_id: 123_i64, source_type: "article")  # More specific

# Mark chunks as read
memo.mark_as_read(chunk_ids: [1_i64, 2_i64])

# Close connection
memo.close
```

### Search Results

```crystal
struct Memo::Search::Result
  getter chunk_id : Int64
  getter source_type : String
  getter source_id : Memo::ExternalId?  # Int64, String or Bytes, as indexed
  getter score : Float64                # Cosine similarity
  getter pair_id : Memo::ExternalId?
  getter parent_id : Memo::ExternalId?
  getter text : String?  # When include_text: true
end
```

### Search Notes

- **`min_score` is a silent cutoff** (default 0.7): results scoring below it are dropped, so "nothing similar"
  and "close but below 0.7" both return an empty list. If your application decides what counts as a match,
  pass `min_score: -1.0` (no cutoff) and compare `score` yourself. Scores aren't comparable across
  embedding models.
- **Filters** (`source_type`, `like`, `match`, `sql_where`) are applied by searching first and checking the
  nearest candidates against the filter; a filter that matches few rows is ranked exactly over its matches.
- **`sql_where` is raw SQL** added to the query. Pass values with `?` placeholders and `sql_where_args`, and
  never build it from untrusted input. On PostgreSQL every `?` outside quotes is a placeholder, so jsonb's
  `?`, `?|` and `?&` operators can't be used; use `jsonb_exists()` and friends.
- `track_matches: false` (Service option) stops searches from updating match counts, so searches don't write.

## Storage

Memo keeps its data in the database (a SQLite file at `db_path`, or PostgreSQL) and an index file per
embedding service beside it:

- **Database**: services, embeddings (deduplicated by content hash), chunks, texts, the embed queue,
  every embedding's vector (`memo_vectors`, 16-bit floats), and a journal of index changes
  (`memo_index_log`)
- **USearch index**: an HNSW index file per service (e.g. `memo.openai--text-embedding-3-small--1536.usearch`),
  held in memory while open, with a `.checkpoint` and a `.lock` file beside it

The index is rebuilt from the database whenever it needs to be, so **backing up the database is enough**
(e.g. Litestream for SQLite). Text storage can be disabled with `store_text: false` if you prefer to manage
text separately.

### Durability and Recovery

- Every vector and index change is written in the same transaction as the data it belongs to.
- The index file is saved on a policy: once `index_save_changes` (default 10,000) changes are unsaved, or
  any have been unsaved for `index_save_interval` (default 5 minutes). Saves run on a separate thread, so
  searches continue. `memo.save_index_if_due` is cheap to call often; `memo.save_index` saves now, and
  `memo.close` saves before closing.
- Opening an index replays only the changes since its last save. A missing, corrupt or stale index file is
  rebuilt from stored vectors. Neither calls the embedding API. `memo.index_recovery` reports what was done.
- **One process per index.** Opening an index takes a lock; a second process (or a second `Memo::Service`)
  opening the same one raises `Memo::USearchIndex::InUse`. That includes the memo CLI against a database a
  running service has open.

### Concurrency

- A `Memo::Service` can be shared by fibers on Crystal's default, single-threaded execution context
  (e.g. one per web request). It is not safe across threads.
- On SQLite, memo's write transactions take the write lock up front (`BEGIN IMMEDIATE`), and memo's own
  connections wait up to 5 s for a lock (`busy_timeout=5000`). If you pass memo your own connection
  (`Memo::Service.new(db: ...)`), add `?busy_timeout=5000` to its URL too.
- For your own atomic work with memo's tables, use `Memo::Database.transaction(db) { |cnn| ... }` and send
  every statement through `cnn`: statements sent to the pool run on other connections and commit on their own.

## PostgreSQL

```crystal
require "memo"
require "memo/pg"

memo = Memo::Service.new(
  db_path: "postgres://user:pass@host/memo_db",
  index_dir: "/var/lib/memo/indices",  # where the USearch index files go
  service: "openai",
  api_key: ENV["OPENAI_API_KEY"]
)
```

## Bus Service (`memo-arcana`)

`memo-arcana` serves memo's API at `memo:rag` on an Arcana bus, with each namespace (`ns`) an isolated
database, index and embedding service. Namespaces are listed in `/etc/memo/namespaces.yaml` (or
`MEMO_NAMESPACES`), with `${VAR}` expansion from the environment:

```yaml
namespaces:
  - ns: notes
    db: /var/lib/memo/notes.db
    service: openai
    api_key: ${OPENAI_API_KEY}
    preload: true
```

| Variable | Default | |
|---|---|---|
| `ARCANA_HOST`, `ARCANA_PORT` | `127.0.0.1`, `19118` | The bus to join |
| `MEMO_NAMESPACES` | `/etc/memo/namespaces.yaml` | Namespace config |
| `MEMO_MAX_CONCURRENCY` | `32` | Requests handled at once |
| `MEMO_MAX_WAITING` | 8x concurrency | Requests waiting for a turn; beyond that, memo answers with an error carrying `"code": "busy"`, which callers can retry |
| `MEMO_SAVE_INTERVAL` | `60` | Seconds between checks for an index save that's due |

Any client on the bus can open namespaces (including arbitrary database paths), so run it on a trusted bus.
See [SECURITY.md](SECURITY.md).

## Providers

Currently supported:
- `openai` - OpenAI text-embedding-3-small (default), text-embedding-3-large. For text-embedding-3 models,
  a service's `dimensions` is sent to the API, so smaller vectors work. Also works with OpenAI-compatible
  APIs via `base_url`.
- `voyage` - Voyage AI voyage-3 (default), voyage-3-lite, voyage-code-3
- `arcana/openai`, `arcana/voyage` - The same APIs through [arcana-ai](https://github.com/trans/arcana-ai)'s embedders
- `bus/openai`, `bus/voyage` - Embeddings from an `openai:embed` / `voyage:embed` service on the Arcana bus
- `mock` - Deterministic embeddings for testing

The OpenAI and Voyage providers reuse connections and retry rate limits (429), server errors and network
errors, waiting as `Retry-After` says. An exhausted OpenAI quota isn't retried.

## Changes

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT
