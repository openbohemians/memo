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

      # The index file under its 0.12 name gave up its vectors, and took the new name
      memo.index_recovery.missing.should eq 0
      File.exists?(Memo::USearchIndex.index_path_in_dir(index_dir, "mock", "mock-8d", 8)).should be_false
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

  it "keeps databases sharing an index_dir apart" do
    with_pg_database do |a_url, index_dir|
      with_pg_database do |b_url, _|
        a = open_pg(a_url, index_dir)
        b = open_pg(b_url, index_dir)
        File.basename(a.index_path).should start_with "#{URI.parse(a_url).path.lchop('/')}-"
        a.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla")
        b.index(source_type: "doc", source_id: 1_i64, text: "grape ape")
        a.close
        b.close

        a = open_pg(a_url, index_dir)
        a.index_recovery.rebuilt.should eq 0
        a.search(query: "purple gorilla", min_score: 0.99).size.should eq 1
        a.close
      end
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

  it "resolves and indexes a new source id from concurrent fibers" do
    with_pg_database do |url, index_dir|
      service = open_pg(url, index_dir)
      # The race is in timing, so run it for many new ids
      resolved = Channel({Int64, Int64 | Exception}).new
      (1_i64..20_i64).each do |external_id|
        8.times do
          spawn do
            resolved.send({external_id, Memo::SourceRegistry.resolve(service.db, "doc", external_id)})
          rescue ex
            resolved.send({external_id, ex})
          end
        end
      end
      results = Array.new(160) { resolved.receive }
      results.map(&.[1]).select(Exception).map(&.message).should be_empty
      results.group_by(&.[0]).transform_values(&.map(&.[1]).uniq!.size).values.uniq!.should eq [1]

      indexed = Channel(Exception?).new
      8.times do
        spawn do
          service.index(source_type: "doc", source_id: 77_i64, text: "the same text")
          indexed.send(nil)
        rescue ex
          indexed.send(ex)
        end
      end
      Array.new(8) { indexed.receive }.compact.map(&.message).should be_empty
      pg_count(service, "memo_sources WHERE external_int = 77").should eq 1
      service.close
    end
  end

  it "clusters consecutive sources with similar embeddings" do
    with_pg_database do |url, index_dir|
      service = open_pg(url, index_dir)
      (1_i64..3_i64).each { |i| service.index(source_type: "event", source_id: i, text: "the dragon attacks the village") }
      (4_i64..6_i64).each { |i| service.index(source_type: "event", source_id: i, text: "a quiet morning at the market") }

      clusters = Memo::Clustering.sequential(db: service.db, service_id: service.service_id,
        usearch_index: service.usearch_index, source_type: "event", external_ids: (1_i64..6_i64).to_a,
        threshold: 0.99, min_cluster_size: 3)
      clusters.map(&.source_ids).should eq [[1_i64, 2_i64, 3_i64], [4_i64, 5_i64, 6_i64]]
      service.close
    end
  end

  it "deletes a service with vocabulary and cached queries" do
    with_pg_database do |url, index_dir|
      service = open_pg(url, index_dir)
      service.create_service(name: "mock2", format: "mock", model: "mock-model", dimensions: 8, max_tokens: 100)
      service.use_service("mock2")
      service.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      service.search("purple gorilla")
      id = service.service_id
      service.use_service("mock")

      service.delete_service("mock2", force: true).should be_true
      service.get_service("mock2").should be_nil
      pg_count(service, "memo_vocab WHERE service_id = #{id}").should eq 0
      pg_count(service, "memo_query_cache WHERE service_id = #{id}").should eq 0
      service.close
    end
  end
end
