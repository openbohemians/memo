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

private def typed_ids(results : Array(Memo::Search::Result)) : Array({String, Int64})
  results.map { |r| {r.source_type, r.source_id.as(Int64)} }.sort!
end

# Sources 1 (private) and 2 (public) share a text; 3 (public) has its own
private def with_shared_text(&)
  with_test_service do |service|
    service.index(source_type: "private", source_id: 1_i64, text: "the secret plan")
    service.index(source_type: "public", source_id: 2_i64, text: "the secret plan")
    service.index(source_type: "public", source_id: 3_i64, text: "an open letter")
    yield service
  end
end

describe "Filtered search over a text several sources share" do
  it "returns only the sources a source_type filter passes" do
    with_shared_text do |service|
      results = service.search(query: "the secret plan", limit: 1, min_score: -1.0, source_type: "public")
      typed_ids(results).should eq [{"public", 2_i64}]
    end
  end

  it "returns only the sources sql_where passes" do
    with_shared_text do |service|
      results = service.search(query: "the secret plan", min_score: -1.0,
        sql_where: "c.source_type = ?", sql_where_args: ["public"] of DB::Any)
      typed_ids(results).should eq [{"public", 2_i64}, {"public", 3_i64}]
    end
  end

  it "returns only the source an id filter names" do
    with_shared_text do |service|
      results = service.search(query: "the secret plan", min_score: -1.0, source_type: "private", source_id: 1_i64)
      typed_ids(results).should eq [{"private", 1_i64}]
    end
  end

  it "returns only the sources like and match pass" do
    with_shared_text do |service|
      typed_ids(service.search(query: "the secret plan", min_score: -1.0, source_type: "public", like: "%secret%"))
        .should eq [{"public", 2_i64}]
      typed_ids(service.search(query: "the secret plan", min_score: -1.0, source_type: "public", match: "secret"))
        .should eq [{"public", 2_i64}]
    end
  end

  it "fetches no more of one embedding's chunks than the limit" do
    with_test_service do |service|
      (1..30).each { |i| service.index(source_type: "doc", source_id: i.to_i64, text: "the same words") }
      rowid = service.db.scalar("SELECT rowid FROM memo_embeddings").as(Int64)
      rows = service.db.memo_queries.fetch_search_results(
        service.service_id, [service.service_id.as(DB::Any)], ["e.service_id = ?"], "", "", [rowid], false, 3)
      rows.size.should eq 3

      results = service.search(query: "the same words", limit: 3, min_score: -1.0)
      ids(results).should eq [1_i64, 2_i64, 3_i64]
    end
  end
end

describe "Search id filters" do
  it "find nothing for an id that names no source" do
    with_test_service do |service|
      service.index(source_type: "doc", source_id: 1_i64, text: "alpha")
      service.search(query: "alpha", min_score: -1.0, source_type: "doc", source_id: 999_i64).should be_empty
      service.search(query: "alpha", min_score: -1.0, source_type: "doc", pair_id: 999_i64).should be_empty
      service.search(query: "alpha", min_score: -1.0, source_type: "doc", parent_id: 999_i64).should be_empty
      service.search(query: "alpha", min_score: -1.0, source_type: "doc", source_id: 1_i64).size.should eq 1
    end
  end

  it "need a source_type" do
    with_test_service do |service|
      expect_raises(ArgumentError, /need source_type/) do
        service.search(query: "alpha", source_id: 1_i64)
      end
    end
  end

  it "refuse like and match when the text isn't stored" do
    with_test_db_path do |db_path|
      service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50, store_text: false)
      service.index(source_type: "doc", source_id: 1_i64, text: "alpha")
      expect_raises(ArgumentError, /store_text/) { service.search(query: "alpha", like: "%alpha%") }
      expect_raises(ArgumentError, /store_text/) { service.search(query: "alpha", match: "alpha") }
      service.search(query: "alpha", min_score: -1.0).size.should eq 1
      service.close
    end
  end
end
