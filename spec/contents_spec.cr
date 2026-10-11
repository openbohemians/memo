require "./spec_helper"

# Record the texts the mock provider is asked to embed, and let a spec act
# during the "API call"
class Memo::Providers::Mock
  class_getter embedded = [] of String
  class_property on_embed : Proc(Array(String), Nil)? = nil

  def embed_texts(texts : Array(String), input_type : String? = nil) : EmbedResult
    @@embedded.concat(texts)
    @@on_embed.try &.call(texts)
    previous_def
  end
end

# Lets a spec make embedded_hashes claim one hash has an embedding when it
# doesn't, as if another writer deleted it right after the lookup
class Memo::Queries::SQLite
  class_property claim_embedded : Bytes? = nil

  def embedded_hashes(hashes : Array(Bytes), service_id : Int64) : Set(Bytes)
    found = previous_def
    if hash = @@claim_embedded
      @@claim_embedded = nil
      found << hash
    end
    found
  end
end

private def embedded_during(&) : Array(String)
  Memo::Providers::Mock.embedded.clear
  yield
  Memo::Providers::Mock.embedded.dup
end

private def open_memo(db_path : String, store_text = true, chunk_tokens = 50) : Memo::Service
  Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: chunk_tokens, build_vocab: false, store_text: store_text)
end

private def with_memo(store_text = true, chunk_tokens = 50, &)
  with_test_db_path do |db_path|
    memo = open_memo(db_path, store_text, chunk_tokens)
    begin
      yield memo
    ensure
      memo.close
    end
  end
end

private def count(memo : Memo::Service, table : String) : Int64
  memo.db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64)
end

private def internal_id(memo : Memo::Service, id : Int64) : Int64
  Memo::SourceRegistry.get_internal(memo.db, "doc", id) || raise "no source #{id}"
end

# A paragraph that makes a chunk of its own: memo combines chunks under 100
# tokens, and can't split one sentence
private def paragraph(word : String) : String
  ([word] * 90).join(" ") + "."
end

private def paragraphs(*words : String) : String
  words.map { |word| paragraph(word) }.join("\n\n")
end

describe "Content-addressed storage" do
  it "stores a text once for every source that has it" do
    with_memo do |memo|
      memo.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla")
      memo.index(source_type: "doc", source_id: 2_i64, text: "a purple gorilla")

      count(memo, "memo_contents").should eq 1
      count(memo, "memo_chunks").should eq 2
      count(memo, "memo_embeddings").should eq 1
      memo.db.query_all("SELECT DISTINCT content_id FROM memo_sources", as: Int64?).size.should eq 1
      memo.get_source_text(internal_id(memo, 2_i64)).should eq "a purple gorilla"
    end
  end

  it "doesn't send the API a text it has embedded for another source" do
    with_memo do |memo|
      embedded_during { memo.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla") }.should eq ["a purple gorilla"]
      embedded_during { memo.index(source_type: "doc", source_id: 2_i64, text: "a purple gorilla").should eq 1 }.should be_empty
    end
  end

  it "skips a source already indexed with the same text" do
    with_memo do |memo|
      memo.index(source_type: "doc", source_id: 1_i64, text: "a grape ape").should eq 1
      embedded_during { memo.index(source_type: "doc", source_id: 1_i64, text: "a grape ape").should eq -1 }.should be_empty
      count(memo, "memo_chunks").should eq 1
    end
  end

  it "sends only the changed chunks of an edited text" do
    with_memo(chunk_tokens: 100) do |memo|
      memo.index(source_type: "doc", source_id: 1_i64, text: paragraphs("alpha", "beta", "gamma")).should eq 3

      sent = embedded_during do
        memo.index(source_type: "doc", source_id: 1_i64, text: paragraphs("alpha", "delta", "gamma")).should eq 3
      end
      sent.should eq [paragraph("delta")]
      count(memo, "memo_embeddings").should eq 3 # beta's went with it
      count(memo, "memo_contents").should eq 1
    end
  end

  it "rebuilds the chunks, without the API, when only the parent changes" do
    with_memo do |memo|
      memo.index(source_type: "doc", source_id: 1_i64, text: "a grape ape", parent_id: 10_i64)
      sent = embedded_during do
        memo.index(source_type: "doc", source_id: 1_i64, text: "a grape ape", parent_id: 11_i64).should eq 1
      end
      sent.should be_empty
      memo.search(query: "a grape ape", min_score: -1.0).first.parent_id.should eq 11_i64
    end
  end

  it "deletes a text and its embeddings once no source uses them" do
    with_memo do |memo|
      memo.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla")
      memo.index(source_type: "doc", source_id: 2_i64, text: "a purple gorilla")

      memo.delete(1_i64, "doc")
      count(memo, "memo_contents").should eq 1
      count(memo, "memo_embeddings").should eq 1

      memo.delete(2_i64, "doc")
      count(memo, "memo_contents").should eq 0
      count(memo, "memo_embeddings").should eq 0
    end
  end

  it "keeps only the hash when the application stores its own text" do
    with_memo(store_text: false) do |memo|
      memo.index(source_type: "doc", source_id: 1_i64, text: "a grape ape")
      memo.db.query_one("SELECT content FROM memo_contents", as: String?).should be_nil
      memo.get_source_text(internal_id(memo, 1_i64)).should be_nil

      embedded_during { memo.index(source_type: "doc", source_id: 1_i64, text: "a grape ape").should eq -1 }.should be_empty
    end
  end

  it "fills in a text first stored without it" do
    with_test_db_path do |db_path|
      without_text = open_memo(db_path, store_text: false)
      without_text.index(source_type: "doc", source_id: 1_i64, text: "a grape ape")
      without_text.close

      memo = open_memo(db_path)
      memo.index(source_type: "doc", source_id: 2_i64, text: "a grape ape")
      count(memo, "memo_contents").should eq 1
      memo.get_source_text(internal_id(memo, 1_i64)).should eq "a grape ape"
      results = memo.search(query: "ape", min_score: -1.0, match: "grape", include_text: true)
      results.compact_map(&.source_id.as?(Int64)).sort!.should eq [1_i64, 2_i64]
      results.map(&.text).uniq!.should eq ["a grape ape"]
      memo.close
    end
  end

  it "makes a queued text readable at once, while search results keep the embedded one" do
    with_memo do |memo|
      memo.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla")
      memo.enqueue(source_type: "doc", source_id: 1_i64, text: "a grape ape")

      memo.get_source_text(internal_id(memo, 1_i64)).should eq "a grape ape"
      memo.search(query: "a purple gorilla", min_score: -1.0, include_text: true).first.text.should eq "a purple gorilla"

      memo.process_queue
      memo.search(query: "a grape ape", min_score: -1.0, include_text: true).first.text.should eq "a grape ape"
      count(memo, "memo_contents").should eq 1
    end
  end

  it "drops a queued text once it is embedded" do
    with_memo do |memo|
      memo.enqueue(source_type: "doc", source_id: 1_i64, text: "a grape ape")
      memo.db.query_one("SELECT text FROM memo_embed_queue", as: String?).should_not be_nil
      memo.process_queue
      memo.db.query_one("SELECT text FROM memo_embed_queue", as: String?).should be_nil

      memo.index(source_type: "doc", source_id: 2_i64, text: "a tiny robot")
      memo.db.query_all("SELECT text FROM memo_embed_queue", as: String?).compact.should be_empty
    end
  end

  it "embeds a text queued while the source's previous one was being embedded" do
    with_memo do |memo|
      memo.enqueue(source_type: "doc", source_id: 1_i64, text: "a purple gorilla")
      Memo::Providers::Mock.on_embed = ->(texts : Array(String)) do
        if texts.includes?("a purple gorilla")
          memo.enqueue(source_type: "doc", source_id: 1_i64, text: "a grape ape")
        end
        nil
      end

      begin
        embedded_during { memo.process_queue.should eq 2 }.should eq ["a purple gorilla", "a grape ape"]
      ensure
        Memo::Providers::Mock.on_embed = nil
      end
      memo.queue_stats.pending.should eq 0
      memo.search(query: "a grape ape", min_score: -1.0, include_text: true).map(&.text).should eq ["a grape ape"]
      memo.get_source_text(internal_id(memo, 1_i64)).should eq "a grape ape"
    end
  end

  it "embeds again if an embedding it meant to reuse is deleted meanwhile" do
    with_memo do |memo|
      Memo::Queries::SQLite.claim_embedded = Memo::Storage.compute_hash("a grape ape")
      sent = embedded_during { memo.index(source_type: "doc", source_id: 1_i64, text: "a grape ape").should eq 1 }
      Memo::Queries::SQLite.claim_embedded.should be_nil # the claim was made
      sent.should eq ["a grape ape"]
      count(memo, "memo_embeddings").should eq 1
      memo.search(query: "a grape ape", min_score: -1.0).size.should eq 1
    end
  end
end

# A database as memo 0.12 left it: one text per source in memo_texts, an
# FTS row per source, and a queue that kept every text.
private def create_0_12_database(db_path : String) : Nil
  db = DB.open("sqlite3://#{db_path}")
  File.read("#{__DIR__}/fixtures/memo_schema_0.12.sql").split(";").each do |statement|
    db.exec(statement) unless statement.lines.all? { |line| line.strip.empty? || line.strip.starts_with?("--") }
  end
  mock = db.scalar("SELECT id FROM memo_services WHERE name = 'mock'").as(Int64)
  sha = ->(text : String) { Memo::Storage.compute_hash(text) }

  shared, queued, older = "a purple gorilla", "a grape ape", "an old ape"
  {1, 2, 3}.each { |i| db.exec("INSERT INTO memo_sources (id, source_type, external_int, created_at) VALUES (?, 'doc', ?, 0)", i, i) }

  # Sources 1 and 2 are embedded (hash set). Source 3 has a new text queued
  # (no hash yet); its chunk is from an older text.
  db.exec("INSERT INTO memo_texts (source_id, content, content_hash, created_at) VALUES (1, ?, ?, 0), (2, ?, ?, 0), (3, ?, NULL, 0)",
    shared, sha.call(shared), shared, sha.call(shared), queued)
  db.exec("INSERT INTO memo_texts_fts (rowid, source_id, content) SELECT source_id, source_id, content FROM memo_texts")
  db.exec("INSERT INTO memo_embeddings (hash, service_id, token_count, created_at) VALUES (?, ?, 4, 0), (?, ?, 3, 0)",
    sha.call(shared), mock, sha.call(older), mock)
  db.exec("INSERT INTO memo_chunks (hash, source_id, source_type, offset, size, created_at) VALUES (?, 1, 'doc', 0, 16, 0), (?, 2, 'doc', 0, 16, 0), (?, 3, 'doc', 0, 10, 0)",
    sha.call(shared), sha.call(shared), sha.call(older))
  db.exec("INSERT INTO memo_embed_queue (source_id, text, status, created_at) VALUES (1, ?, 0, 0), (3, ?, -1, 0)",
    "MEMO_META:doc,,\n#{shared}", "MEMO_META:doc,,\n#{queued}")

  # 0.12 kept the vectors only in the index file
  index = Memo::USearchIndex.open(Memo::USearchIndex.index_path(db_path, "mock", "mock-8d", 8), 8)
  {shared, older}.each do |text|
    rowid = db.scalar("SELECT rowid FROM memo_embeddings WHERE hash = ?", sha.call(text)).as(Int64)
    Memo::USearchIndex.add(index, rowid.to_u64, Memo::Providers::Mock.new.embed_text(text)[0])
  end
  Memo::USearchIndex.save(index, Memo::USearchIndex.index_path(db_path, "mock", "mock-8d", 8))
  db.close
end

describe Memo::Migration do
  it "converts a database from memo 0.12" do
    with_test_db_path do |db_path|
      create_0_12_database(db_path)
      memo = open_memo(db_path)
      dialect = memo.db.memo_dialect

      Memo::Migration.version(memo.db).should eq Memo::Migration::SCHEMA_VERSION
      dialect.table_exists?(memo.db, "memo_texts").should be_false
      dialect.table_exists?(memo.db, "memo_texts_fts").should be_false

      # Each distinct text once, with sources and chunks pointing at it
      memo.db.query_all("SELECT content FROM memo_contents ORDER BY id", as: String).should eq ["a purple gorilla", "a grape ape"]
      gorilla, ape = memo.db.query_all("SELECT id FROM memo_contents ORDER BY id", as: Int64)
      memo.db.query_all("SELECT content_id FROM memo_sources ORDER BY id", as: Int64?).should eq [gorilla, gorilla, ape]
      # Source 3's chunk was cut from a text no longer stored
      memo.db.query_all("SELECT content_id FROM memo_chunks ORDER BY source_id", as: Int64?).should eq [gorilla, gorilla, nil]

      memo.db.query_all("SELECT rowid FROM memo_contents_fts WHERE memo_contents_fts MATCH 'gorilla'", as: Int64).should eq [gorilla]
      memo.db.exec("INSERT INTO memo_contents_fts (memo_contents_fts) VALUES ('integrity-check')")

      # The finished queue item lost its text; the pending one kept it
      memo.db.query_all("SELECT text IS NULL FROM memo_embed_queue ORDER BY source_id", as: Bool).should eq [true, false]

      embedded_during { memo.index(source_type: "doc", source_id: 1_i64, text: "a purple gorilla").should eq -1 }.should be_empty
      embedded_during { memo.process_queue }.should eq ["a grape ape"]
      memo.db.query_all("SELECT content_id FROM memo_chunks ORDER BY source_id", as: Int64?).should eq [gorilla, gorilla, ape]
      memo.close
    end
  end

  it "leaves a migrated database alone" do
    with_test_db_path do |db_path|
      create_0_12_database(db_path)
      open_memo(db_path).close

      memo = open_memo(db_path)
      memo.db.exec("CREATE TABLE memo_texts (source_id INTEGER, content TEXT, content_hash BLOB)")
      Memo::Migration.run(memo.db)
      memo.db.memo_dialect.table_exists?(memo.db, "memo_texts").should be_true
      memo.close
    end
  end

  it "refuses a database from a newer memo" do
    with_test_db_path do |db_path|
      open_memo(db_path).tap(&.db.exec("UPDATE memo_meta SET value = '99' WHERE key = 'schema_version'")).close
      expect_raises(Memo::Migration::NewerSchema, "schema version 99") { open_memo(db_path) }
    end
  end
end
