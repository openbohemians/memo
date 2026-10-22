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

# A database as memo 0.12 left it (see contents_spec): sources 1 and 2
# share an embedded text, source 3 has a new text queued.
private def create_0_12_pg_database(url : String, index_dir : String) : Nil
  db = DB.open(url)
  db.using_connection { |cnn| cnn.as(PG::Connection).exec_all(File.read("#{__DIR__}/fixtures/memo_schema_pg_0.12.sql")) }
  mock = db.scalar("SELECT id FROM memo_services WHERE name = 'mock'").as(Int64)
  sha = ->(text : String) { Memo::Storage.compute_hash(text) }
  shared, queued, older = "a purple gorilla", "a grape ape", "an old ape"

  {1, 2, 3}.each { |i| db.exec("INSERT INTO memo_sources (id, source_type, external_int, created_at) VALUES ($1, 'doc', $2, 0)", i, i.to_i64) }
  db.exec("INSERT INTO memo_texts (source_id, content, content_hash, created_at) VALUES (1, $1, $2, 0), (2, $3, $4, 0), (3, $5, NULL, 0)",
    shared, sha.call(shared), shared, sha.call(shared), queued)
  db.exec("INSERT INTO memo_embeddings (hash, service_id, token_count, created_at) VALUES ($1, $2, 4, 0), ($3, $4, 3, 0)",
    sha.call(shared), mock, sha.call(older), mock)
  db.exec("INSERT INTO memo_chunks (hash, source_id, source_type, \"offset\", size, created_at) VALUES ($1, 1, 'doc', 0, 16, 0), ($2, 2, 'doc', 0, 16, 0), ($3, 3, 'doc', 0, 10, 0)",
    sha.call(shared), sha.call(shared), sha.call(older))
  db.exec("INSERT INTO memo_embed_queue (source_id, text, status, created_at) VALUES (1, $1, 0, 0), (3, $2, -1, 0)",
    "MEMO_META:doc,,\n#{shared}", "MEMO_META:doc,,\n#{queued}")

  path = Memo::USearchIndex.index_path_in_dir(index_dir, "mock", "mock-8d", 8)
  index = Memo::USearchIndex.open(path, 8)
  {shared, older}.each do |text|
    eid = db.scalar("SELECT eid FROM memo_embeddings WHERE hash = $1", sha.call(text)).as(Int64)
    Memo::USearchIndex.add(index, eid.to_u64, Memo::Providers::Mock.new.embed_text(text)[0])
  end
  Memo::USearchIndex.save(index, path)
  db.close
end

describe "PostgreSQL backend" do
  it "stores a text once for every source that has it, and searches it" do
    with_pg_database do |url, index_dir|
      memo = open_pg(url, index_dir)
      memo.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      memo.index(source_type: "doc", source_id: 2_i64, text: "purple gorilla in a top hat")
      memo.index(source_type: "doc", source_id: 3_i64, text: "tiny haunted robot")
      pg_count(memo, "memo_contents").should eq 2
      memo.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat").should eq -1

      found = memo.search(query: "gorilla", min_score: -1.0, match: "gorilla", include_text: true)
      pg_ids(found).sort!.should eq [1_i64, 2_i64]
      found.map(&.text).uniq!.should eq ["purple gorilla in a top hat"]
      pg_ids(memo.search(query: "gorilla", min_score: -1.0, like: "%robot%")).should eq [3_i64]

      memo.delete(1_i64, "doc")
      memo.delete(2_i64, "doc")
      pg_count(memo, "memo_contents").should eq 1
      memo.close
    end
  end

  it "converts a database from memo 0.12" do
    with_pg_database do |url, index_dir|
      create_0_12_pg_database(url, index_dir)
      memo = open_pg(url, index_dir)

      Memo::Migration.version(memo.db).should eq Memo::Migration::SCHEMA_VERSION
      memo.db.memo_dialect.table_exists?(memo.db, "memo_texts").should be_false
      memo.db.query_all("SELECT content FROM memo_contents ORDER BY id", as: String).should eq ["a purple gorilla", "a grape ape"]
      gorilla, ape = memo.db.query_all("SELECT id FROM memo_contents ORDER BY id", as: Int64)
      memo.db.query_all("SELECT content_id FROM memo_sources ORDER BY id", as: Int64?).should eq [gorilla, gorilla, ape]
      memo.db.query_all("SELECT content_id FROM memo_chunks ORDER BY source_id", as: Int64?).should eq [gorilla, gorilla, nil]
      memo.db.query_all("SELECT text IS NULL FROM memo_embed_queue ORDER BY source_id", as: Bool).should eq [true, false]

      memo.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla").should eq -1
      memo.process_queue
      pg_ids(memo.search(query: "ape", min_score: -1.0, match: "grape")).should eq [3_i64]
      memo.close
    end
  end

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

  it "opens a listed service by format and model, past a copy an earlier memo added" do
    with_pg_database do |url, index_dir|
      service = open_pg(url, index_dir)
      listed_id = service.service_id
      service.db.exec("INSERT INTO memo_services (name, format, model, dimensions, max_tokens, created_at) VALUES ('mock/mock-8d', 'mock', 'mock-8d', 8, 100, 0)")
      service.close

      service = Memo::Service.new(db_path: url, index_dir: index_dir, format: "mock", model: "mock-8d", chunking_max_tokens: 50)
      service.service_id.should eq listed_id
      service.service_name.should eq "mock"
      pg_count(service, "memo_services WHERE format = 'mock'").should eq 2
      service.close
    end
  end

  it "returns only the sources the filters pass, when sources share a text" do
    with_pg_database do |url, index_dir|
      service = open_pg(url, index_dir)
      service.index(source_type: "private", source_id: 1_i64, text: "the secret plan")
      service.index(source_type: "public", source_id: 2_i64, text: "the secret plan")
      service.index(source_type: "public", source_id: 3_i64, text: "an open letter")

      found = ->(results : Array(Memo::Search::Result)) { results.map { |result| {result.source_type, result.source_id.as(Int64)} }.sort! }
      found.call(service.search(query: "the secret plan", limit: 1, min_score: -1.0, source_type: "public"))
        .should eq [{"public", 2_i64}]
      found.call(service.search(query: "the secret plan", min_score: -1.0, sql_where: "c.source_type = ?", sql_where_args: ["public"] of DB::Any))
        .should eq [{"public", 2_i64}, {"public", 3_i64}]
      found.call(service.search(query: "the secret plan", min_score: -1.0, source_type: "public", match: "secret"))
        .should eq [{"public", 2_i64}]
      service.search(query: "the secret plan", min_score: -1.0, source_type: "public", source_id: 999_i64).should be_empty
      service.close
    end
  end
end
