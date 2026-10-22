require "./spec_helper"

# Helper to create a USearch index, store embeddings, and create chunks for search tests.
# Returns the USearch index with all vectors added.
private def setup_search_index(
  db : DB::Database,
  service_id : Int64,
  entries : Array({String, Array(Float64), String, Int64}),  # text, embedding, source_type, external_id
  dimensions : Int32 = 8
) : USearch::Index
  index = USearch::Index.new(dimensions: dimensions, metric: :cos, quantization: :f16)

  entries.each do |text, embedding, source_type, external_id|
    hash = Memo::Storage.compute_hash(text)
    inserted, rowid = Memo::Storage.store_embedding(db, hash, 10, service_id)
    Memo::USearchIndex.add(index, rowid.to_u64, embedding) if inserted
    internal_id = create_test_source(db, source_type, external_id)
    Memo::Storage.create_chunk(db, hash, source_type, internal_id, 0, 100)
  end

  index
end

describe Memo::Search do
  describe ".semantic" do
    it "returns empty results when no embeddings exist" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",
          dimensions: 8,
          max_tokens: 1000
        )

        index = USearch::Index.new(dimensions: 8, metric: :cos, quantization: :f16)
        query_embedding = Array.new(8) { |i| i.to_f64 }

        results = Memo::Search.semantic(
          db: db,
          embedding: query_embedding,
          service_id: service_id,
          usearch_index: index,
          limit: 10
        )

        results.should be_empty
        index.close
      end
    end

    it "returns matching results ranked by similarity" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",
          dimensions: 8,
          max_tokens: 1000
        )

        index = setup_search_index(db, service_id, [
          {"first", [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "document", 0_i64},
          {"second", [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "document", 1_i64},
          {"third", [0.9, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "document", 2_i64},
        ])

        query_embedding = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

        results = Memo::Search.semantic(
          db: db,
          embedding: query_embedding,
          service_id: service_id,
          usearch_index: index,
          limit: 10,
          min_score: 0.5
        )

        results.size.should be >= 2
        results[0].score.should be >= results[1].score if results.size > 1
        index.close
      end
    end

    it "filters by source_type" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",
          dimensions: 8,
          max_tokens: 1000
        )

        embedding = Array.new(8) { |i| (i + 1).to_f64 / 8.0 }

        index = setup_search_index(db, service_id, [
          {"text1", embedding, "document", 1_i64},
          {"text2", embedding, "event", 2_i64},
        ])

        filters = Memo::Search::Filters.new(source_type: "document")
        results = Memo::Search.semantic(
          db: db,
          embedding: embedding,
          service_id: service_id,
          usearch_index: index,
          filters: filters
        )

        results.size.should eq(1)
        results[0].source_type.should eq("document")
        index.close
      end
    end

    it "only returns results from same service" do
      with_test_db do |db|
        service1_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "openai",
          base_url: nil,
          model: "text-embedding-3-small",
          dimensions: 8,
          max_tokens: 8191
        )

        service2_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "openai",
          base_url: nil,
          model: "text-embedding-3-large",
          dimensions: 8,
          max_tokens: 8191
        )

        embedding = Array.new(8) { |i| (i + 1).to_f64 / 8.0 }

        # Create index for service1 only
        index = USearch::Index.new(dimensions: 8, metric: :cos, quantization: :f16)

        hash1 = Memo::Storage.compute_hash("text1")
        inserted1, rowid1 = Memo::Storage.store_embedding(db, hash1, 10, service1_id)
        Memo::USearchIndex.add(index, rowid1.to_u64, embedding) if inserted1
        internal_id1 = create_test_source(db, "document", 1_i64)
        Memo::Storage.create_chunk(db, hash1, "document", internal_id1, 0, 100)

        # Service2 embedding not added to this USearch index
        hash2 = Memo::Storage.compute_hash("text2")
        Memo::Storage.store_embedding(db, hash2, 10, service2_id)
        internal_id2 = create_test_source(db, "document", 2_i64)
        Memo::Storage.create_chunk(db, hash2, "document", internal_id2, 0, 100)

        results = Memo::Search.semantic(
          db: db,
          embedding: embedding,
          service_id: service1_id,
          usearch_index: index
        )

        results.size.should eq(1)
        results[0].source_id.should eq(1_i64)
        index.close
      end
    end

    it "respects min_score threshold" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",
          dimensions: 8,
          max_tokens: 1000
        )

        # Store embedding very different from query
        index = setup_search_index(db, service_id, [
          {"text", [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], "document", 1_i64},
        ])

        query_embedding = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

        results = Memo::Search.semantic(
          db: db,
          embedding: query_embedding,
          service_id: service_id,
          usearch_index: index,
          min_score: 0.9
        )

        results.should be_empty
        index.close
      end
    end

    it "increments match_count for returned results" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",
          dimensions: 8,
          max_tokens: 1000
        )

        embedding = Array.new(8) { |i| (i + 1).to_f64 / 8.0 }
        index = setup_search_index(db, service_id, [
          {"text", embedding, "document", 1_i64},
        ])

        chunk_id = db.scalar("SELECT id FROM memo_chunks LIMIT 1").as(Int64)

        # Search twice
        2.times do
          Memo::Search.semantic(
            db: db,
            embedding: embedding,
            service_id: service_id,
            usearch_index: index
          )
        end

        match_count = db.scalar(
          "SELECT match_count FROM memo_chunks WHERE id = ?",
          chunk_id
        ).as(Int64)

        match_count.should eq(2)
        index.close
      end
    end

    it "takes a limit larger than the index" do
      with_test_service do |memo|
        3.times { |i| memo.index(source_type: "doc", source_id: i.to_i64, text: "purple gorilla number #{i}") }

        memo.search(query: "purple gorilla", limit: Int32::MAX, min_score: -1.0).size.should eq 3
      end
    end

    it "takes a limit larger than the index with filters" do
      with_test_service do |memo|
        3.times { |i| memo.index(source_type: "doc", source_id: i.to_i64, text: "purple gorilla number #{i}") }

        memo.search(query: "purple gorilla", limit: Int32::MAX, min_score: -1.0, source_type: "doc").size.should eq 3
      end
    end
  end

  describe ".mark_as_read" do
    it "increments read_count for specified chunks" do
      with_test_db do |db|
        service_id = Memo::Storage.register_service(
          db: db,
          name: nil,
          format: "mock",
          base_url: nil,
          model: "test-model",
          dimensions: 8,
          max_tokens: 1000
        )

        embedding = Array.new(8) { |i| (i + 1).to_f64 / 8.0 }
        hash = Memo::Storage.compute_hash("text")
        Memo::Storage.store_embedding(db, hash, 10, service_id)
        internal_id = create_test_source(db, "document", 1_i64)
        chunk_id = Memo::Storage.create_chunk(db, hash, "document", internal_id, 0, 100)

        # Mark as read twice
        2.times do
          Memo::Search.mark_as_read(db, [chunk_id])
        end

        read_count = db.scalar(
          "SELECT read_count FROM memo_chunks WHERE id = ?",
          chunk_id
        ).as(Int64)

        read_count.should eq(2)
      end
    end
  end
end
