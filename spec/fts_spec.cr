require "./spec_helper"

private def fts_rows(service : Memo::Service) : Array({Int64, Int64})
  service.db.query_all("SELECT rowid, source_id FROM memo_texts_fts ORDER BY rowid", as: {Int64, Int64})
end

describe "Full-text index" do
  it "replaces a source's row when it is indexed again" do
    with_test_service do |service|
      service.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla")
      service.index(source_type: "doc", source_id: 1_i64, text: "a grape ape")

      fts_rows(service).size.should eq 1
      service.search(query: "ape", min_score: 0.0, match: "grape").size.should eq 1
      service.search(query: "ape", min_score: 0.0, match: "gorilla").should be_empty
    end
  end

  it "finds a source's row without scanning the table" do
    with_test_service do |service|
      plan = service.db.query_all("EXPLAIN QUERY PLAN DELETE FROM memo_texts_fts WHERE rowid = 1", as: {Int64, Int64, Int64, String})
      # A virtual table's plan always reads "SCAN ... VIRTUAL TABLE INDEX n:<arg>".
      # FTS5's "=" argument means a rowid lookup; an empty one, a full scan.
      plan.map(&.[3]).join(" ").should contain("INDEX 0:=")
    end
  end

  it "migrates rows from databases that predate rowid = source_id" do
    with_test_db_path do |db_path|
      service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
      3.times { |i| service.index(source_type: "doc", source_id: i.to_i64, text: "creature number #{i}") }

      # The old layout: rows under unrelated rowids, and no migration marker
      service.db.exec("DELETE FROM memo_texts_fts")
      service.db.exec("INSERT INTO memo_texts_fts (rowid, source_id, content) SELECT source_id + 1000, source_id, content FROM memo_texts")
      service.db.exec("DELETE FROM memo_meta WHERE key = 'fts_rowid_is_source_id'")
      service.close

      reopened = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
      rows = fts_rows(reopened)
      rows.size.should eq 3
      rows.all? { |rowid, source_id| rowid == source_id }.should be_true
      reopened.search(query: "creature", min_score: 0.0, match: "creature").size.should eq 3
      reopened.close
    end
  end

  it "skips the migration if another process finished it first" do
    with_test_service do |service|
      service.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla")
      # A row a rebuild would drop: proves the rebuild didn't run again
      service.db.exec("INSERT INTO memo_texts_fts (rowid, source_id, content) VALUES (999, 999, 'marker row')")

      # As if this process passed migrate's check just before another
      # process committed the migration
      Memo::Dialect::SQLite.new.migrate_fts_rowids(service.db)
      fts_rows(service).map(&.[0]).should contain(999_i64)
    end
  end

  it "opens its own SQLite connections with a busy timeout" do
    with_test_service do |service|
      service.db.scalar("PRAGMA busy_timeout").as(Int64).should eq 5000
    end
  end
end
