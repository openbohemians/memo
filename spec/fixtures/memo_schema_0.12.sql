-- Consolidated Memo Schema (SQLite)
--
-- All tables use the "memo_" prefix to avoid conflicts when sharing
-- a database with other applications.

-- =============================================================================
-- AI embedding service registry
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_services (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    format TEXT NOT NULL,
    base_url TEXT,
    model TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    max_tokens INTEGER NOT NULL,
    tokens_per_byte REAL DEFAULT 0.25,
    is_default INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS memo_idx_services_format ON memo_services(format);
CREATE INDEX IF NOT EXISTS memo_idx_services_default ON memo_services(is_default);

-- Preload services

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai', 'openai', NULL, 'text-embedding-3-small', 1536, 8191, 1, 0);

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai/text-embedding-3-large', 'openai', NULL, 'text-embedding-3-large', 3072, 8191, 0, 0);

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai/text-embedding-ada-002', 'openai', NULL, 'text-embedding-ada-002', 1536, 8191, 0, 0);

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage', 'voyage', NULL, 'voyage-3', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-3-lite', 'voyage', NULL, 'voyage-3-lite', 512, 32000, 0, 0);

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-code-3', 'voyage', NULL, 'voyage-code-3', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-finance-2', 'voyage', NULL, 'voyage-finance-2', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-law-2', 'voyage', NULL, 'voyage-law-2', 1024, 32000, 0, 0);

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('mock', 'mock', NULL, 'mock-8d', 8, 100, 0, 0);

-- Bus-routed services: route embedding requests through the Arcana bus
-- (openai:embed / voyage:embed) instead of calling the API directly.
-- Requires memo-arcana to be running with a connected Arcana::Client.

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai-bus', 'bus/openai', NULL, 'text-embedding-3-small', 1536, 8191, 0, 0);

INSERT OR IGNORE INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage-bus', 'bus/voyage', NULL, 'voyage-3', 1024, 32000, 0, 0);

-- =============================================================================
-- Embeddings registry
--
-- The SQLite rowid serves as the USearch key for vector lookup.
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_embeddings (
    hash BLOB NOT NULL,
    service_id INTEGER NOT NULL,
    token_count INTEGER NOT NULL,
    created_at INTEGER NOT NULL,

    PRIMARY KEY (hash, service_id),
    FOREIGN KEY (service_id) REFERENCES memo_services(id)
);

CREATE INDEX IF NOT EXISTS memo_idx_embeddings_service ON memo_embeddings(service_id);

-- =============================================================================
-- Sources table
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_type TEXT NOT NULL,
    external_int INTEGER,
    external_text TEXT,
    external_blob BLOB,
    created_at INTEGER NOT NULL,

    UNIQUE(source_type, external_int),
    UNIQUE(source_type, external_text),
    UNIQUE(source_type, external_blob)
);

CREATE INDEX IF NOT EXISTS memo_idx_sources_type_int ON memo_sources(source_type, external_int)
    WHERE external_int IS NOT NULL;
CREATE INDEX IF NOT EXISTS memo_idx_sources_type_text ON memo_sources(source_type, external_text)
    WHERE external_text IS NOT NULL;
CREATE INDEX IF NOT EXISTS memo_idx_sources_type_blob ON memo_sources(source_type, external_blob)
    WHERE external_blob IS NOT NULL;

-- =============================================================================
-- Chunks table
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hash BLOB NOT NULL,

    source_id INTEGER NOT NULL REFERENCES memo_sources(id),
    source_type TEXT NOT NULL,

    pair_id INTEGER REFERENCES memo_sources(id),
    parent_id INTEGER REFERENCES memo_sources(id),

    offset INTEGER,
    size INTEGER NOT NULL,

    match_count INTEGER NOT NULL DEFAULT 0,
    read_count INTEGER NOT NULL DEFAULT 0,

    created_at INTEGER NOT NULL,

    UNIQUE(source_id, offset)
);

CREATE INDEX IF NOT EXISTS memo_idx_chunks_hash ON memo_chunks(hash);
CREATE INDEX IF NOT EXISTS memo_idx_chunks_source ON memo_chunks(source_type, source_id);
CREATE INDEX IF NOT EXISTS memo_idx_chunks_pair ON memo_chunks(pair_id) WHERE pair_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS memo_idx_chunks_parent ON memo_chunks(parent_id) WHERE parent_id IS NOT NULL;

-- =============================================================================
-- Embedding queue
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_embed_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL REFERENCES memo_sources(id),
    text TEXT,
    status INTEGER NOT NULL DEFAULT -1,
    error_message TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    processed_at INTEGER,

    UNIQUE(source_id)
);

CREATE INDEX IF NOT EXISTS memo_idx_queue_pending ON memo_embed_queue(status) WHERE status = -1;
CREATE INDEX IF NOT EXISTS memo_idx_queue_retries ON memo_embed_queue(status, attempts) WHERE status > 0;

-- =============================================================================
-- Text storage
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_texts (
    source_id INTEGER PRIMARY KEY REFERENCES memo_sources(id),
    content TEXT NOT NULL,
    content_hash BLOB,
    created_at INTEGER NOT NULL
);

-- FTS5 virtual table for full-text search
CREATE VIRTUAL TABLE IF NOT EXISTS memo_texts_fts
USING fts5(source_id UNINDEXED, content);

-- =============================================================================
-- Vocabulary table
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_vocab (
    word TEXT NOT NULL,
    service_id INTEGER NOT NULL,
    embedding BLOB NOT NULL,
    frequency INTEGER DEFAULT 1,
    created_at INTEGER NOT NULL,

    PRIMARY KEY (word, service_id),
    FOREIGN KEY (service_id) REFERENCES memo_services(id)
);

CREATE INDEX IF NOT EXISTS memo_idx_vocab_service ON memo_vocab(service_id);

-- =============================================================================
-- Files table
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_files (
    source_id INTEGER PRIMARY KEY REFERENCES memo_sources(id),
    path TEXT NOT NULL,
    content_hash BLOB NOT NULL,
    mtime INTEGER NOT NULL,
    size INTEGER NOT NULL,
    created_at INTEGER NOT NULL,

    UNIQUE(path)
);

CREATE INDEX IF NOT EXISTS memo_idx_files_hash ON memo_files(content_hash);

-- =============================================================================
-- Query embedding cache
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_query_cache (
    query TEXT NOT NULL,
    service_id INTEGER NOT NULL,
    embedding BLOB NOT NULL,
    token_count INTEGER NOT NULL,
    created_at INTEGER NOT NULL,

    PRIMARY KEY (query, service_id),
    FOREIGN KEY (service_id) REFERENCES memo_services(id)
);

CREATE INDEX IF NOT EXISTS memo_idx_query_cache_service ON memo_query_cache(service_id, created_at);
