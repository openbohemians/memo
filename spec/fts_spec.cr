require "./spec_helper"

private def fts_matches(service : Memo::Service, query : String) : Array(Int64)
  service.db.query_all("SELECT rowid FROM memo_contents_fts WHERE memo_contents_fts MATCH ? ORDER BY rowid", query, as: Int64)
end

# Raises if the full-text index differs from the texts in memo_contents
private def check_fts(service : Memo::Service)
  service.db.exec("INSERT INTO memo_contents_fts (memo_contents_fts) VALUES ('integrity-check')")
end

describe "Full-text index" do
  it "follows a source to its new text when it is indexed again" do
    with_test_service do |service|
      service.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla")
      service.index(source_type: "doc", source_id: 1_i64, text: "a grape ape")

      fts_matches(service, "gorilla").should be_empty
      service.search(query: "ape", min_score: 0.0, match: "grape").size.should eq 1
      service.search(query: "ape", min_score: 0.0, match: "gorilla").should be_empty
      check_fts(service)
    end
  end

  it "indexes a text shared by several sources once, and finds each source" do
    with_test_service do |service|
      service.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla")
      service.index(source_type: "doc", source_id: 2_i64, text: "a purple gorilla")

      fts_matches(service, "gorilla").size.should eq 1
      results = service.search(query: "gorilla", min_score: -1.0, match: "gorilla")
      results.compact_map(&.source_id.as?(Int64)).sort!.should eq [1_i64, 2_i64]
    end
  end

  it "stays in step with the texts as they come and go" do
    with_test_service do |service|
      service.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla")
      service.index(source_type: "doc", source_id: 2_i64, text: "a purple gorilla")
      service.index(source_type: "doc", source_id: 3_i64, text: "a grape ape")
      service.index(source_type: "doc", source_id: 3_i64, text: "a tiny robot")
      service.delete(1_i64, "doc")
      check_fts(service)
      fts_matches(service, "gorilla").size.should eq 1

      service.delete(2_i64, "doc")
      check_fts(service)
      fts_matches(service, "gorilla").should be_empty
      fts_matches(service, "ape").should be_empty
      fts_matches(service, "robot").size.should eq 1
    end
  end

  it "finds a text's row without scanning the table" do
    with_test_service do |service|
      plan = service.db.query_all("EXPLAIN QUERY PLAN SELECT * FROM memo_contents_fts WHERE rowid = 1", as: {Int64, Int64, Int64, String})
      # A virtual table's plan always reads "SCAN ... VIRTUAL TABLE INDEX n:<arg>".
      # FTS5's "=" argument means a rowid lookup; an empty one, a full scan.
      plan.map(&.[3]).join(" ").should contain("INDEX 0:=")
    end
  end

  it "opens its own SQLite connections with a busy timeout" do
    with_test_service do |service|
      service.db.scalar("PRAGMA busy_timeout").as(Int64).should eq 5000
    end
  end
end
