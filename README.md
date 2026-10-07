# Memo

Semantic search and vector storage library for Crystal.

## Features

- **CLI tool** - Index, search, and manage from the command line
- **Text chunking** - Smart segmentation into optimal-sized pieces
- **Embedding storage** - Deduplication by content hash
- **HNSW search** - Fast approximate nearest neighbor via USearch
- **Text storage** - Optional persistent text with LIKE and FTS5 full-text search

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
puts "Pending: #{stats[:pending]}, Failed: #{stats[:failed]}"

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
  getter source_id : Int64
  getter score : Float64
  getter pair_id : Int64?
  getter parent_id : Int64?
  getter text : String?  # When include_text: true
end
```

## Storage

Memo stores data in a SQLite file at the specified `db_path` plus USearch index files alongside it:

- **SQLite**: Services, embeddings registry, chunks, texts, and queue
- **USearch**: HNSW index files (one per service, e.g. `openai--text-embedding-3-small--1536.usearch`)

Vectors are stored in USearch HNSW indexes for fast approximate nearest neighbor search.
The SQLite embeddings table serves as a deduplication registry (content hash tracking).

Text storage can be disabled with `store_text: false` if you prefer to manage text separately.

## Providers

Currently supported:
- `openai` - OpenAI text-embedding-3-small (default), text-embedding-3-large
- `voyage` - Voyage AI voyage-3 (default), voyage-3-lite, voyage-code-3
- `mock` - Deterministic embeddings for testing

## License

MIT
