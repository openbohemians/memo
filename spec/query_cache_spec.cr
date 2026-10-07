require "./spec_helper"

private def cached_rows(db : DB::Database) : Int64
  db.scalar("SELECT COUNT(*) FROM memo_query_cache").as(Int64)
end

describe Memo::QueryCache do
  it "keeps the persistent cache at max_db_entries" do
    with_test_db do |db|
      cache = Memo::QueryCache.new(max_entries: 10, max_db_entries: 5, db: db, service_id: 1_i64)
      8.times { |i| cache.put("query #{i}", [0.5, 0.25], 3) }
      cached_rows(db).should eq 5
      cache.get("query 7").should_not be_nil
    end
  end

  it "checks a large cache's size once per 1% of max_db_entries writes" do
    with_test_db do |db|
      cache = Memo::QueryCache.new(max_entries: 10, max_db_entries: 300, db: db, service_id: 1_i64)
      310.times { |i| cache.put("query #{i}", [0.5, 0.25], 3) }
      # Pruned at the check after write 300; at most 3 writes (1%) since
      cached_rows(db).should be >= 300
      cached_rows(db).should be <= 303
    end
  end
end
