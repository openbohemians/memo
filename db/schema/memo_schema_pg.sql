-- Consolidated Memo Schema (PostgreSQL)
--
-- All tables use the "memo_" prefix to avoid conflicts when sharing
-- a database with other applications.

-- =============================================================================
-- AI embedding service registry
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_services (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    format TEXT NOT NULL,
    base_url TEXT,
    model TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    max_tokens INTEGER NOT NULL,
    tokens_per_byte DOUBLE PRECISION DEFAULT 0.25,
    is_default INTEGER DEFAULT 0,
    created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS memo_idx_services_format ON memo_services(format);
CREATE INDEX IF NOT EXISTS memo_idx_services_default ON memo_services(is_default);

-- Preload services

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai', 'openai', NULL, 'text-embedding-3-small', 1536, 8191, 1, 0)
ON CONFLICT (name) DO NOTHING;

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai/text-embedding-3-large', 'openai', NULL, 'text-embedding-3-large', 3072, 8191, 0, 0)
ON CONFLICT (name) DO NOTHING;

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai/text-embedding-ada-002', 'openai', NULL, 'text-embedding-ada-002', 1536, 8191, 0, 0)
ON CONFLICT (name) DO NOTHING;

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage', 'voyage', NULL, 'voyage-3', 1024, 32000, 0, 0)
ON CONFLICT (name) DO NOTHING;

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-3-lite', 'voyage', NULL, 'voyage-3-lite', 512, 32000, 0, 0)
ON CONFLICT (name) DO NOTHING;

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-code-3', 'voyage', NULL, 'voyage-code-3', 1024, 32000, 0, 0)
ON CONFLICT (name) DO NOTHING;

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-finance-2', 'voyage', NULL, 'voyage-finance-2', 1024, 32000, 0, 0)
ON CONFLICT (name) DO NOTHING;

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage/voyage-law-2', 'voyage', NULL, 'voyage-law-2', 1024, 32000, 0, 0)
ON CONFLICT (name) DO NOTHING;

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('mock', 'mock', NULL, 'mock-8d', 8, 100, 0, 0)
ON CONFLICT (name) DO NOTHING;

-- Bus-routed services: route embedding requests through the Arcana bus
-- (openai:embed / voyage:embed) instead of calling the API directly.
-- Requires memo-arcana to be running with a connected Arcana::Client.

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('openai-bus', 'bus/openai', NULL, 'text-embedding-3-small', 1536, 8191, 0, 0)
ON CONFLICT (name) DO NOTHING;

INSERT INTO memo_services (name, format, base_url, model, dimensions, max_tokens, is_default, created_at)
VALUES ('voyage-bus', 'bus/voyage', NULL, 'voyage-3', 1024, 32000, 0, 0)
ON CONFLICT (name) DO NOTHING;

-- =============================================================================
-- Embeddings registry
--
-- eid column serves as the USearch key (replaces SQLite implicit rowid).
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_embeddings (
    eid BIGSERIAL UNIQUE NOT NULL,
    hash BYTEA NOT NULL,
    service_id BIGINT NOT NULL,
    token_count INTEGER NOT NULL,
    created_at BIGINT NOT NULL,

    PRIMARY KEY (hash, service_id),
    FOREIGN KEY (service_id) REFERENCES memo_services(id)
);

CREATE INDEX IF NOT EXISTS memo_idx_embeddings_service ON memo_embeddings(service_id);

-- =============================================================================
-- Contents
--
-- One row per distinct text, keyed by its hash. Sources with the same text
-- share a row. content is NULL when the application keeps its own text
-- (store_text: false): the hash alone still tells memo whether a source's
-- text has changed. content_tsv indexes the text for full-text search.
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_contents (
    id BIGSERIAL PRIMARY KEY,
    hash BYTEA NOT NULL UNIQUE,
    content TEXT,
    content_tsv TSVECTOR,
    created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS memo_idx_contents_fts ON memo_contents USING GIN(content_tsv);

-- Auto-populate tsvector on insert/update
CREATE OR REPLACE FUNCTION memo_contents_tsv_trigger() RETURNS trigger AS $$
BEGIN
    NEW.content_tsv := to_tsvector('english', NEW.content);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'memo_trg_contents_tsv'
    ) THEN
        CREATE TRIGGER memo_trg_contents_tsv
            BEFORE INSERT OR UPDATE OF content ON memo_contents
            FOR EACH ROW EXECUTE FUNCTION memo_contents_tsv_trigger();
    END IF;
END;
$$;

-- =============================================================================
-- Sources table
--
-- A source is the application's handle on one item: its type and external
-- id. content_id points at its latest text, set as soon as the text is
-- indexed or queued.
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_sources (
    id BIGSERIAL PRIMARY KEY,
    source_type TEXT NOT NULL,
    external_int BIGINT,
    external_text TEXT,
    external_blob BYTEA,
    content_id BIGINT REFERENCES memo_contents(id),
    created_at BIGINT NOT NULL,

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

-- Databases from before 0.13 lack content_id
ALTER TABLE memo_sources ADD COLUMN IF NOT EXISTS content_id BIGINT REFERENCES memo_contents(id);

CREATE INDEX IF NOT EXISTS memo_idx_sources_content ON memo_sources(content_id)
    WHERE content_id IS NOT NULL;

-- =============================================================================
-- Chunks table
--
-- A source's chunks: each is the part of a text (content_id) at offset and
-- size, and its hash keys the embedding. The rows are per source, so
-- filters can name c.source_id, while the texts and embeddings they point
-- at are shared.
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_chunks (
    id BIGSERIAL PRIMARY KEY,
    hash BYTEA NOT NULL,

    source_id BIGINT NOT NULL REFERENCES memo_sources(id),
    source_type TEXT NOT NULL,
    content_id BIGINT REFERENCES memo_contents(id),

    pair_id BIGINT REFERENCES memo_sources(id),
    parent_id BIGINT REFERENCES memo_sources(id),

    "offset" INTEGER,
    size INTEGER NOT NULL,

    match_count INTEGER NOT NULL DEFAULT 0,
    read_count INTEGER NOT NULL DEFAULT 0,

    created_at BIGINT NOT NULL,

    UNIQUE(source_id, "offset")
);

CREATE INDEX IF NOT EXISTS memo_idx_chunks_hash ON memo_chunks(hash);
CREATE INDEX IF NOT EXISTS memo_idx_chunks_source ON memo_chunks(source_type, source_id);
CREATE INDEX IF NOT EXISTS memo_idx_chunks_pair ON memo_chunks(pair_id) WHERE pair_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS memo_idx_chunks_parent ON memo_chunks(parent_id) WHERE parent_id IS NOT NULL;

-- Databases from before 0.13 lack content_id
ALTER TABLE memo_chunks ADD COLUMN IF NOT EXISTS content_id BIGINT REFERENCES memo_contents(id);

CREATE INDEX IF NOT EXISTS memo_idx_chunks_content ON memo_chunks(content_id);

-- =============================================================================
-- Embedding queue
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_embed_queue (
    id BIGSERIAL PRIMARY KEY,
    source_id BIGINT NOT NULL REFERENCES memo_sources(id),
    text TEXT,
    status INTEGER NOT NULL DEFAULT -1,
    error_message TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    processed_at BIGINT,

    UNIQUE(source_id)
);

CREATE INDEX IF NOT EXISTS memo_idx_queue_pending ON memo_embed_queue(status) WHERE status = -1;
CREATE INDEX IF NOT EXISTS memo_idx_queue_retries ON memo_embed_queue(status, attempts) WHERE status > 0;

-- =============================================================================
-- Vocabulary table
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_vocab (
    word TEXT NOT NULL,
    service_id BIGINT NOT NULL,
    embedding BYTEA NOT NULL,
    frequency INTEGER DEFAULT 1,
    created_at BIGINT NOT NULL,

    PRIMARY KEY (word, service_id),
    FOREIGN KEY (service_id) REFERENCES memo_services(id)
);

CREATE INDEX IF NOT EXISTS memo_idx_vocab_service ON memo_vocab(service_id);

-- =============================================================================
-- Files table
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_files (
    source_id BIGINT PRIMARY KEY REFERENCES memo_sources(id),
    path TEXT NOT NULL,
    content_hash BYTEA NOT NULL,
    mtime BIGINT NOT NULL,
    size BIGINT NOT NULL,
    created_at BIGINT NOT NULL,

    UNIQUE(path)
);

CREATE INDEX IF NOT EXISTS memo_idx_files_hash ON memo_files(content_hash);

-- =============================================================================
-- Query embedding cache
-- =============================================================================

CREATE TABLE IF NOT EXISTS memo_query_cache (
    query TEXT NOT NULL,
    service_id BIGINT NOT NULL,
    embedding BYTEA NOT NULL,
    token_count INTEGER NOT NULL,
    created_at BIGINT NOT NULL,

    PRIMARY KEY (query, service_id),
    FOREIGN KEY (service_id) REFERENCES memo_services(id)
);

CREATE INDEX IF NOT EXISTS memo_idx_query_cache_service ON memo_query_cache(service_id, created_at);

-- =============================================================================
-- Stored vectors and index journal
--
-- memo_vectors keeps every embedding's vector (IEEE 16-bit floats, the
-- precision the USearch index stores), so the index can be rebuilt without
-- calling the embedding API. memo_index_log records each embedding added or
-- removed, in the same transaction as the change. On open, memo replays the
-- entries newer than the index file's checkpoint. memo_index_state tracks how
-- far the log has been pruned and whether older vectors have been backfilled.
-- =============================================================================

-- The schema version (see Memo::Migration)
CREATE TABLE IF NOT EXISTS memo_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memo_vectors (
    embedding_id BIGINT PRIMARY KEY, -- memo_embeddings eid
    service_id BIGINT NOT NULL,
    vector BYTEA NOT NULL
);

CREATE INDEX IF NOT EXISTS memo_idx_vectors_service ON memo_vectors(service_id);

CREATE TABLE IF NOT EXISTS memo_index_log (
    seq BIGSERIAL PRIMARY KEY,
    service_id BIGINT NOT NULL,
    embedding_id BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS memo_idx_index_log_service ON memo_index_log(service_id, seq);

CREATE TABLE IF NOT EXISTS memo_index_state (
    service_id BIGINT PRIMARY KEY,
    pruned_through BIGINT NOT NULL DEFAULT 0,
    vectors_backfilled INTEGER NOT NULL DEFAULT 0
);
