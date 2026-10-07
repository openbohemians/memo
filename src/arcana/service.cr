require "../memo"
require "./namespaces"
require "json"

module Memo
  # Arcana bus service wrapper. Routes requests to per-namespace
  # Memo::Service instances for multi-project isolation.
  class ArcanaService
    SCHEMA = JSON.parse(%({"type":"object","required":["action"],"properties":{"action":{"type":"string","enum":["open","close","list","index","index_batch","search","delete","stats","help"]},"ns":{"type":"string"},"db":{"type":"string"},"service":{"type":"string"},"source_type":{"type":"string"},"source_id":{"type":"string"},"text":{"type":"string"},"documents":{"type":"array"},"query":{"type":"string"},"limit":{"type":"integer"},"min_score":{"type":"number"}}}))

    GUIDE = <<-GUIDE
    Memo semantic search service — multi-namespace router.

    Each `ns` (namespace) has its own isolated embedding space: separate
    database, USearch index, and embedding service.

    Management actions:
      open   — Register and open a namespace. Params: ns, db, [service, format, api_key, model, index_dir]
      close  — Close a namespace. Params: ns
      list   — List registered namespaces.

    Data actions (all require `ns`):
      index        — Index a document. Params: ns, source_type, source_id, text
      index_batch  — Index multiple documents. Params: ns, documents (array of {source_type, source_id, text})
      search       — Semantic search. Params: ns, query, limit (default 10), min_score (default 0.7), source_type
      delete       — Delete a document. Params: ns, source_id, source_type
      stats        — Get index statistics. Params: ns

    Examples:
      {"action": "open", "ns": "wow", "db": "postgres://wow:wow@localhost/wow_dev", "service": "openai"}
      {"action": "index", "ns": "wow", "source_type": "claim", "source_id": "42", "text": "..."}
      {"action": "search", "ns": "wow", "query": "bitcoin", "limit": 5}
      {"action": "stats", "ns": "wow"}
    GUIDE

    getter namespaces : Namespaces

    def initialize(@namespaces : Namespaces)
    end

    def handle(data : JSON::Any) : JSON::Any
      action = data["action"]?.try(&.as_s?) || raise "missing action"

      case action
      when "open"        then handle_open(data)
      when "close"       then handle_close(data)
      when "list"        then handle_list
      when "index"       then with_memo(data) { |memo| handle_index(memo, data) }
      when "index_batch" then with_memo(data) { |memo| handle_index_batch(memo, data) }
      when "search"      then with_memo(data) { |memo| handle_search(memo, data) }
      when "delete"      then with_memo(data) { |memo| handle_delete(memo, data) }
      when "stats"       then with_memo(data) { |memo| handle_stats(memo, data) }
      when "help"        then JSON::Any.new({"guide" => JSON::Any.new(GUIDE)})
      else                    raise "unknown action: #{action}"
      end
    end

    # =========================================================================
    # Namespace management
    # =========================================================================

    private def handle_open(data : JSON::Any) : JSON::Any
      ns = data["ns"]?.try(&.as_s?) || raise "missing ns"
      db = data["db"]?.try(&.as_s?) || raise "missing db"

      config = Namespaces::Config.new(
        ns: ns,
        db: db,
        service: data["service"]?.try(&.as_s?),
        format: data["format"]?.try(&.as_s?),
        api_key: data["api_key"]?.try(&.as_s?),
        model: data["model"]?.try(&.as_s?),
        index_dir: data["index_dir"]?.try(&.as_s?),
      )
      @namespaces.open(config)
      JSON::Any.new({"ok" => JSON::Any.new(true), "ns" => JSON::Any.new(ns)})
    end

    private def handle_close(data : JSON::Any) : JSON::Any
      ns = data["ns"]?.try(&.as_s?) || raise "missing ns"
      closed = @namespaces.close(ns)
      JSON::Any.new({"ok" => JSON::Any.new(true), "closed" => JSON::Any.new(closed)})
    end

    private def handle_list : JSON::Any
      items = @namespaces.list.map do |ns, opened|
        JSON::Any.new({
          "ns"     => JSON::Any.new(ns),
          "opened" => JSON::Any.new(opened),
        } of String => JSON::Any)
      end
      JSON::Any.new({"ok" => JSON::Any.new(true), "namespaces" => JSON::Any.new(items)})
    end

    # =========================================================================
    # Data actions
    # =========================================================================

    # Run the block with the request's namespace service; closing the
    # namespace waits for it (see Namespaces#use)
    private def with_memo(data : JSON::Any, &)
      ns = data["ns"]?.try(&.as_s?) || raise "missing ns"
      @namespaces.use(ns) { |memo| yield memo }
    end

    private def handle_index(memo : Memo::Service, data : JSON::Any) : JSON::Any
      source_type = data["source_type"]?.try(&.as_s?) || raise "missing source_type"
      text = data["text"]?.try(&.as_s?) || raise "missing text"
      source_id = parse_source_id(data["source_id"]?)

      chunks = memo.index(source_type: source_type, source_id: source_id, text: text)
      JSON::Any.new({"ok" => JSON::Any.new(true), "chunks" => JSON::Any.new(chunks.to_i64)})
    end

    private def handle_index_batch(memo : Memo::Service, data : JSON::Any) : JSON::Any
      docs_json = data["documents"]?.try(&.as_a?) || raise "missing documents"

      docs = docs_json.map do |d|
        st = d["source_type"]?.try(&.as_s?) || raise "missing source_type in document"
        sid = parse_source_id(d["source_id"]?) || raise "missing source_id in document"
        txt = d["text"]?.try(&.as_s?) || raise "missing text in document"
        Memo::Document.new(source_type: st, source_id: sid, text: txt)
      end

      chunks = memo.index_batch(docs)
      JSON::Any.new({"ok" => JSON::Any.new(true), "chunks" => JSON::Any.new(chunks.to_i64)})
    end

    private def handle_search(memo : Memo::Service, data : JSON::Any) : JSON::Any
      query = data["query"]?.try(&.as_s?) || raise "missing query"
      limit = data["limit"]?.try(&.as_i?) || 10
      min_score = data["min_score"]?.try(&.as_f?) || 0.7
      source_type = data["source_type"]?.try(&.as_s?)

      results, timings = memo.search_with_timings(
        query: query,
        limit: limit.to_i32,
        min_score: min_score,
        source_type: source_type,
      )

      items = results.map do |r|
        h = {
          "score"       => JSON::Any.new(r.score),
          "text"        => JSON::Any.new(r.text || ""),
          "source_type" => JSON::Any.new(r.source_type),
          "source_id"   => json_any_from_external_id(r.source_id),
          "chunk_id"    => JSON::Any.new(r.chunk_id),
        } of String => JSON::Any
        JSON::Any.new(h)
      end

      JSON::Any.new({
        "ok"      => JSON::Any.new(true),
        "results" => JSON::Any.new(items),
        "timings" => JSON::Any.new({
          "embed_ms"  => JSON::Any.new(timings.embed_ms),
          "search_ms" => JSON::Any.new(timings.search_ms),
          "total_ms"  => JSON::Any.new(timings.total_ms),
          "cache_hit" => JSON::Any.new(timings.cache_hit),
        }),
      })
    end

    private def handle_delete(memo : Memo::Service, data : JSON::Any) : JSON::Any
      source_id = parse_source_id(data["source_id"]?) || raise "missing source_id"
      source_type = data["source_type"]?.try(&.as_s?)

      deleted = memo.delete(source_id: source_id, source_type: source_type)
      JSON::Any.new({"ok" => JSON::Any.new(true), "deleted" => JSON::Any.new(deleted.to_i64)})
    end

    private def handle_stats(memo : Memo::Service, data : JSON::Any) : JSON::Any
      s = memo.stats
      JSON::Any.new({
        "ok"                 => JSON::Any.new(true),
        "embeddings"         => JSON::Any.new(s.embeddings),
        "chunks"             => JSON::Any.new(s.chunks),
        "sources"            => JSON::Any.new(s.sources),
        "index_memory_bytes" => JSON::Any.new(s.index_memory_bytes.to_i64),
        "index_memory_mb"    => JSON::Any.new(s.index_memory_mb),
        "query_cache_size"   => JSON::Any.new(s.query_cache_size.to_i64),
      })
    end

    private def json_any_from_external_id(id : ExternalId?) : JSON::Any
      case id
      when Int64  then JSON::Any.new(id)
      when String then JSON::Any.new(id)
      else             JSON::Any.new(nil)
      end
    end

    private def parse_source_id(value : JSON::Any?) : ExternalId?
      return nil unless value
      raw = value.raw
      case raw
      when Int64  then raw
      when String then raw.to_i64? || raw
      else             nil
      end
    end
  end
end
