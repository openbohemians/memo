require "./spec_helper"

# 200 documents: every 10th is an "item", the rest are "character"s
private def with_filter_corpus(&)
  with_test_service do |service|
    docs = (0...200).map do |i|
      Memo::Document.new(source_type: i % 10 == 0 ? "item" : "character", source_id: i.to_i64, text: "document #{i}")
    end
    service.index_batch(docs)
    yield service
  end
end

# Source ids of the exact nearest neighbors among embeddings passing `where`
private def exhaustive(service : Memo::Service, query : String, where : String, args : Array(DB::Any), limit : Int32) : Array(Int64)
  embedding, _ = service.provider.embed_text(query, "query")
  keys = service.db.memo_queries.search_filtered_rowids(
    service.service_id, [service.service_id.as(DB::Any)] + args, ["e.service_id = ?", where], "", "")
  Memo::USearchIndex.exact_search(service.usearch_index, embedding, keys, limit).map do |r|
    service.db.scalar(
      "SELECT s.external_int FROM memo_embeddings e JOIN memo_chunks c ON c.hash = e.hash
       JOIN memo_sources s ON s.id = c.source_id WHERE e.rowid = ?", r.key.to_i64).as(Int64)
  end
end

private def ids(results : Array(Memo::Search::Result)) : Array(Int64)
  results.compact_map(&.source_id.as?(Int64))
end

describe "Filtered search" do
  it "answers a broad filter from the nearest candidates" do
    with_filter_corpus do |service|
      results = service.search(query: "query", limit: 10, min_score: 0.0, source_type: "character")
      results.size.should eq 10
      results.all? { |r| r.source_type == "character" }.should be_true
      ids(results).should eq exhaustive(service, "query", "c.source_type = ?", ["character"] of DB::Any, 10)
    end
  end

  it "finds the matches of a narrower filter" do
    with_filter_corpus do |service|
      results = service.search(query: "query", limit: 10, min_score: 0.0, source_type: "item")
      results.size.should eq 10
      results.all? { |r| r.source_type == "item" }.should be_true
      ids(results).should eq exhaustive(service, "query", "c.source_type = ?", ["item"] of DB::Any, 10)
    end
  end

  it "finds a filter's only match" do
    with_filter_corpus do |service|
      results = service.search(query: "query", limit: 10, min_score: 0.0,
        sql_where: "c.source_id = (SELECT id FROM memo_sources WHERE external_int = ?)", sql_where_args: [123_i64] of DB::Any)
      ids(results).should eq [123_i64]
    end
  end

  it "returns every match when fewer than the limit exist" do
    with_filter_corpus do |service|
      results = service.search(query: "query", limit: 10, min_score: 0.0,
        sql_where: "c.source_id IN (SELECT id FROM memo_sources WHERE external_int IN (?, ?, ?))",
        sql_where_args: [5_i64, 50_i64, 150_i64] of DB::Any)
      ids(results).sort.should eq [5_i64, 50_i64, 150_i64]
    end
  end

  it "returns nothing when no row matches" do
    with_filter_corpus do |service|
      service.search(query: "query", limit: 10, min_score: 0.0, source_type: "nothing").should be_empty
    end
  end

  it "keeps only results at or above min_score" do
    with_filter_corpus do |service|
      service.search(query: "query", limit: 10, min_score: 0.99, source_type: "item").each do |r|
        r.score.should be >= 0.99
      end
    end
  end
end
