require "./spec_helper"
require "../src/memo/pg"

# These run only when MEMO_TEST_PG names a PostgreSQL server (see spec_helper).

private def open_pg(url : String, index_dir : String) : Memo::Service
  Memo::Service.new(db_path: url, index_dir: index_dir, service: "mock", chunking_max_tokens: 50)
end

private def pg_count(service : Memo::Service, table : String) : Int64
  service.db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64)
end

private def pg_ids(results : Array(Memo::Search::Result)) : Array(Int64)
  results.compact_map(&.source_id.as?(Int64))
end

private def pg_finds?(service : Memo::Service, text : String, id : Int64) : Bool
  pg_ids(service.search(query: text, min_score: -1.0)).includes?(id)
end

describe "PostgreSQL backend" do
  it "stores vectors and journals index changes with the data" do
    with_pg_database do |url, index_dir|
      memo = open_pg(url, index_dir)
      memo.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      pg_count(memo, "memo_vectors").should eq pg_count(memo, "memo_embeddings")
      pg_count(memo, "memo_index_log").should be > 0
      pg_finds?(memo, "purple gorilla in a top hat", 1_i64).should be_true
      memo.close
    end
  end

  it "rolls back a reindex that fails partway" do
    with_pg_database do |url, index_dir|
      memo = open_pg(url, index_dir)
      memo.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      chunks = memo.stats.chunks

      expect_raises(Exception, "lookup failed") do
        memo.reindex("doc") { |_id| raise "lookup failed" }
      end
      memo.stats.chunks.should eq chunks
      pg_finds?(memo, "purple gorilla in a top hat", 1_i64).should be_true
      memo.close
    end
  end

  it "replays changes made after the last save, after a crash" do
    with_pg_database do |url, index_dir|
      first = open_pg(url, index_dir)
      first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      first.close

      second = open_pg(url, index_dir)
      second.index(source_type: "doc", source_id: 2_i64, text: "tiny haunted robot")
      second.delete(1_i64, "doc")
      second.db.close          # crash: the index is never saved
      second.@index_lock.close # (a crash ends the process, releasing its lock)

      third = open_pg(url, index_dir)
      third.index_recovery.replayed.should eq 2
      pg_finds?(third, "tiny haunted robot", 2_i64).should be_true
      pg_finds?(third, "purple gorilla in a top hat", 1_i64).should be_false
      third.close
    end
  end

  it "rebuilds a lost index file from stored vectors" do
    with_pg_database do |url, index_dir|
      first = open_pg(url, index_dir)
      first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      index_path = first.index_path
      first.close
      File.delete(index_path)

      second = open_pg(url, index_dir)
      second.index_recovery.rebuilt.should eq 1
      pg_finds?(second, "purple gorilla in a top hat", 1_i64).should be_true
      second.close
    end
  end

  it "enqueues in a batch, processes the queue, and deletes" do
    with_pg_database do |url, index_dir|
      memo = open_pg(url, index_dir)
      memo.enqueue_batch([
        Memo::Document.new(source_type: "doc", source_id: 2_i64, text: "grape ape with a monocle"),
        Memo::Document.new(source_type: "doc", source_id: 3_i64, text: "tiny haunted robot"),
      ])
      memo.process_queue.should eq 2
      memo.delete(2_i64, "doc").should eq 1

      pg_finds?(memo, "tiny haunted robot", 3_i64).should be_true
      pg_finds?(memo, "grape ape with a monocle", 2_i64).should be_false
      memo.close
    end
  end

  it "applies filters, including sql_where with ? parameters and a literal '?'" do
    with_pg_database do |url, index_dir|
      memo = open_pg(url, index_dir)
      docs = (0...60).map do |i|
        Memo::Document.new(source_type: i.even? ? "doc" : "note", source_id: i.to_i64, text: "document #{i}")
      end
      memo.index_batch(docs)

      broad = memo.search(query: "document", limit: 10, min_score: -1.0, source_type: "doc")
      broad.size.should eq 10
      broad.all? { |result| result.source_type == "doc" }.should be_true

      sql = "c.source_id IN (SELECT s.id FROM memo_sources s WHERE s.source_type = 'what?' OR s.external_int = ?)"
      args = [42_i64] of DB::Any
      pg_ids(memo.search(query: "document", min_score: -1.0, sql_where: sql, sql_where_args: args)).should eq [42_i64]
      pg_ids(memo.search(query: "document", min_score: -1.0, source_type: "doc", sql_where: sql, sql_where_args: args)).should eq [42_i64]

      memo.search(query: "document", min_score: -1.0, source_type: "nothing").should be_empty
      memo.close
    end
  end
end
