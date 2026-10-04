module Memo
  # Semantic search operations using USearch HNSW index
  module Search
    extend self

    # Per-stage timing breakdown for search operations
    struct Timings
      getter embed_ms : Float64
      getter search_ms : Float64
      getter fetch_ms : Float64
      getter total_ms : Float64
      getter cache_hit : Bool

      def initialize(@embed_ms = 0.0, @search_ms = 0.0, @fetch_ms = 0.0, @total_ms = 0.0, @cache_hit = false)
      end
    end

    # Search result struct
    #
    # Returns external source IDs (Int64, String, or Bytes), matching what was indexed.
    # source_id may be nil for memo-managed sources (e.g., file indexer).
    struct Result
      getter chunk_id : Int64
      getter hash : Bytes
      getter source_type : String
      getter source_id : ExternalId?    # External ID (nil for memo-managed sources)
      getter internal_source_id : Int64 # Internal ID (FK to sources)
      getter pair_id : ExternalId?
      getter parent_id : ExternalId?
      getter offset : Int32?
      getter size : Int32
      getter match_count : Int32
      getter read_count : Int32
      getter score : Float64
      getter text : String? # Only populated with detail level

      def initialize(
        @chunk_id, @hash, @source_type, @source_id, @internal_source_id,
        @pair_id, @parent_id, @offset, @size,
        @match_count, @read_count, @score, @text = nil,
      )
      end
    end

    # Filters for semantic search
    #
    # Uses internal IDs for filtering (resolved by Service.search from external IDs)
    struct Filters
      property source_type : String?
      property internal_source_id : Int64?
      property internal_pair_id : Int64?
      property internal_parent_id : Int64?

      def initialize(
        @source_type = nil,
        @internal_source_id = nil,
        @internal_pair_id = nil,
        @internal_parent_id = nil,
      )
      end
    end

    # Semantic search using USearch HNSW index
    #
    # Returns results ranked by cosine similarity.
    #
    # IMPORTANT: Must provide service_id to ensure embeddings are from same vector space.
    #
    # When metadata filters are present (source_type, like, match, sql_where),
    # pre-filters via SQL to get valid embedding rowids, then uses USearch
    # filtered_search. When no filters, uses direct USearch search.
    def semantic(
      db : DB::Database,
      embedding : Array(Float64),
      service_id : Int64,
      usearch_index : USearch::Index,
      limit : Int32 = 10,
      min_score : Float64 = 0.7,
      filters : Filters? = nil,
      detail : Symbol = :reference,
      sql_where : String? = nil,
      like : Array(String)? = nil,
      match : String? = nil,
      include_text : Bool = true,
      sql_where_args : Array(DB::Any) = [] of DB::Any,
      track_matches : Bool = true,
    ) : Array(Result)
      has_filters = filters || sql_where || (like && !like.empty?) || (match && !match.empty?)

      # Get nearest neighbor candidates from USearch
      usearch_results = if has_filters
                          search_filtered(db, usearch_index, embedding, service_id, limit, filters, sql_where, like, match, sql_where_args)
                        else
                          USearchIndex.search(usearch_index, embedding, limit)
                        end

      return [] of Result if usearch_results.empty?

      # Build score lookup (cosine distance → similarity)
      scores = {} of UInt64 => Float64
      usearch_results.each do |r|
        score = 1.0 - r.distance.to_f64
        next if score < min_score
        scores[r.key] = score
      end

      return [] of Result if scores.empty?

      # Batch-fetch chunk metadata for matching rowids
      fetch_results(db, service_id, scores, limit, include_text, track_matches)
    end

    # Mark chunks as read (increment read_count)
    def mark_as_read(db : DB::Database, chunk_ids : Array(Int64))
      Storage.increment_read_count(db, chunk_ids)
    end

    # Pre-filter via SQL, then use USearch filtered_search
    private def search_filtered(
      db : DB::Database,
      usearch_index : USearch::Index,
      embedding : Array(Float64),
      service_id : Int64,
      limit : Int32,
      filters : Filters?,
      sql_where : String?,
      like : Array(String)?,
      match : String?,
      sql_where_args : Array(DB::Any),
    ) : Array(USearch::SearchResult)
      # Build WHERE clauses and params
      where_clauses = ["e.service_id = ?"] of String
      params = [service_id] of DB::Any

      if f = filters
        if source_type = f.source_type
          where_clauses << "c.source_type = ?"
          params << source_type
        end
        if source_id = f.internal_source_id
          where_clauses << "c.source_id = ?"
          params << source_id
        end
        if pair_id = f.internal_pair_id
          where_clauses << "c.pair_id = ?"
          params << pair_id
        end
        if parent_id = f.internal_parent_id
          where_clauses << "c.parent_id = ?"
          params << parent_id
        end
      end

      if sql_where && !sql_where.empty?
        where_clauses << "(#{sql_where})"
        params.concat(sql_where_args)
      end

      text_join = ""
      fts_join = ""

      if like && !like.empty?
        text_join = "JOIN memo_texts st ON c.source_id = st.source_id"
        like.each do |pattern|
          where_clauses << "st.content LIKE ?"
          params << pattern
        end
      end

      dialect = db.memo_dialect
      if match && !match.empty?
        fts_join = dialect.fts_join_sql
        where_clauses << dialect.fts_where_sql
        params << match
      end

      valid_rowids = db.memo_queries.search_filtered_rowids(service_id, params, where_clauses, text_join, fts_join)
      return [] of USearch::SearchResult if valid_rowids.empty?

      USearchIndex.filtered_search(usearch_index, embedding, limit) do |key|
        valid_rowids.includes?(key)
      end
    end

    # Fetch chunk metadata for USearch results
    private def fetch_results(
      db : DB::Database,
      service_id : Int64,
      scores : Hash(UInt64, Float64),
      limit : Int32,
      include_text : Bool,
      track_matches : Bool,
    ) : Array(Result)
      rowids = scores.keys.map(&.to_i64)
      rows = db.memo_queries.fetch_search_results(rowids, service_id, include_text)

      results = rows.map do |row|
        embedding_rowid, chunk_id, hash, source_type, internal_source_id, external_int, external_text, external_blob, internal_pair_id, pair_external_int, pair_external_text, pair_external_blob, internal_parent_id, parent_external_int, parent_external_text, parent_external_blob, offset, size, match_count, read_count, text_content = row

        score = scores[embedding_rowid]? || 0.0
        external_source_id : ExternalId? = external_int || external_text || external_blob
        external_pair_id : ExternalId? = internal_pair_id ? (pair_external_int || pair_external_text || pair_external_blob) : nil
        external_parent_id : ExternalId? = internal_parent_id ? (parent_external_int || parent_external_text || parent_external_blob) : nil

        Result.new(
          chunk_id: chunk_id, hash: hash, source_type: source_type,
          source_id: external_source_id, internal_source_id: internal_source_id,
          pair_id: external_pair_id, parent_id: external_parent_id,
          offset: offset, size: size,
          match_count: match_count, read_count: read_count,
          score: score, text: text_content
        )
      end

      results.sort_by! { |r| -r.score }
      results = results.first(limit)
      Storage.increment_match_count(db, results.map(&.chunk_id)) if track_matches
      results
    end
  end
end
