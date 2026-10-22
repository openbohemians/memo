require "./spec_helper"

describe Memo::Service do
  describe "#initialize" do
    it "initializes with valid mock config" do
      with_test_service do |service|
        service.service_id.should be > 0
        service.provider.should be_a(Memo::Providers::Mock)
      end
    end

    it "opens USearch index on initialization" do
      with_test_service do |service|
        service.usearch_index.should_not be_nil
      end
    end

    it "persists USearch index across re-initialization" do
      with_test_db_path do |db_path|
        # First initialization - index a document
        service1 = Memo::Service.new(
          db_path: db_path,
          service: "mock",
          chunking_max_tokens: 50
        )
        service_id = service1.service_id
        service1.index(source_type: "event", source_id: 1_i64, text: "Test document")
        service1.close

        # Re-open same database - index should persist
        service2 = Memo::Service.new(
          db_path: db_path,
          service: "mock",
          chunking_max_tokens: 50
        )

        service2.service_id.should eq(service_id)

        # Should be able to search and find the indexed document
        results = service2.search(query: "test", min_score: 0.0)
        results.size.should be > 0

        service2.close
      end
    end

    it "opens a listed service by format and model without copying it" do
      with_test_db_path do |db_path|
        2.times do
          service = Memo::Service.new(db_path: db_path, format: "mock", model: "mock-8d", chunking_max_tokens: 50)
          service.service_name.should eq "mock"
          service.db.scalar("SELECT COUNT(*) FROM memo_services WHERE format = 'mock' AND model = 'mock-8d'").should eq 1
          service.close
        end
      end
    end

    it "opens by format and model where an earlier memo copied the listed service" do
      with_test_db_path do |db_path|
        service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
        listed_id = service.service_id
        service.db.exec("INSERT INTO memo_services (name, format, model, dimensions, max_tokens, created_at) VALUES ('mock/mock-8d', 'mock', 'mock-8d', 8, 100, 0)")
        service.close

        service = Memo::Service.new(db_path: db_path, format: "mock", model: "mock-8d", chunking_max_tokens: 50)
        service.service_id.should eq listed_id
        service.close
      end
    end

    it "validates chunking vs service limits" do
      expect_raises(ArgumentError, /exceeds service limit/) do
        with_test_db_path do |db_path|
          service = Memo::Service.new(
            db_path: db_path,
            service: "mock",
            chunking_max_tokens: 10000, # > mock's 100 limit
            max_tokens: 100
          )
          service.close
        end
      end
    end

    it "requires api_key for openai provider" do
      expect_raises(ArgumentError, /api_key required/) do
        with_test_db_path do |db_path|
          service = Memo::Service.new(
            db_path: db_path,
            service: "openai"
          )
          service.close
        end
      end
    end

    it "rejects unknown format" do
      expect_raises(ArgumentError, /Unknown format/) do
        with_test_db_path do |db_path|
          service = Memo::Service.new(
            db_path: db_path,
            format: "unknown",
            model: "test",
            dimensions: 8,
            max_tokens: 100,
            chunking_max_tokens: 50
          )
          service.close
        end
      end
    end
  end

  describe "#index" do
    it "indexes a simple document" do
      with_test_service do |service|
        count = service.index(
          source_type: "event",
          source_id: 1_i64,
          text: "The quick brown fox jumps over the lazy dog"
        )
        count.should be > 0
      end
    end

    it "returns 0 for empty text" do
      with_test_service do |service|
        count = service.index(
          source_type: "event",
          source_id: 1_i64,
          text: ""
        )
        count.should eq(0)
      end
    end

    it "stores chunks with source metadata" do
      with_test_service do |service|
        service.index(
          source_type: "event",
          source_id: 42_i64,
          text: "Test document"
        )

        # Verify chunk was stored with correct source
        # Join with sources table to get external ID
        
result = service.db.query_one(
          "SELECT c.source_type, s.external_int
           FROM memo_chunks c
           JOIN memo_sources s ON c.source_id = s.id
           LIMIT 1",
          as: {String, Int64}
        )
        result.should eq({"event", 42_i64})
      end
    end

    it "handles pair_id and parent_id" do
      with_test_service do |service|
        service.index(
          source_type: "event",
          source_id: 1_i64,
          text: "Test with relationships",
          pair_id: 99_i64,
          parent_id: 88_i64
        )

        # Verify relationships stored
        # Join with sources table to get external IDs for pair and parent
        
result = service.db.query_one(
          "SELECT ps.external_int, prs.external_int
           FROM memo_chunks c
           LEFT JOIN memo_sources ps ON c.pair_id = ps.id
           LEFT JOIN memo_sources prs ON c.parent_id = prs.id
           LIMIT 1",
          as: {Int64?, Int64?}
        )
        result.should eq({99_i64, 88_i64})
      end
    end

    it "indexes using Document struct" do
      with_test_service do |service|
        doc = Memo::Document.new(
          source_type: "event",
          source_id: 1_i64,
          text: "Document struct test"
        )

        count = service.index(doc)
        count.should be > 0

        stats = service.stats
        stats.sources.should eq(1)
      end
    end
  end

  describe "#index_batch" do
    it "indexes multiple documents in one call" do
      with_test_service do |service|
        docs = [
          Memo::Document.new(source_type: "event", source_id: 1_i64, text: "First document"),
          Memo::Document.new(source_type: "event", source_id: 2_i64, text: "Second document"),
          Memo::Document.new(source_type: "idea", source_id: 3_i64, text: "Third document"),
        ]

        count = service.index_batch(docs)
        count.should eq(3)

        stats = service.stats
        stats.sources.should eq(3)
        stats.chunks.should eq(3)
      end
    end

    it "returns 0 for empty array" do
      with_test_service do |service|
        count = service.index_batch([] of Memo::Document)
        count.should eq(0)
      end
    end

    it "skips documents with empty text" do
      with_test_service do |service|
        docs = [
          Memo::Document.new(source_type: "event", source_id: 1_i64, text: "Valid document"),
          Memo::Document.new(source_type: "event", source_id: 2_i64, text: ""),
          Memo::Document.new(source_type: "event", source_id: 3_i64, text: "Another valid"),
        ]

        count = service.index_batch(docs)
        count.should eq(2)

        stats = service.stats
        stats.sources.should eq(2)
      end
    end

    it "handles Document with pair_id and parent_id" do
      with_test_service do |service|
        docs = [
          Memo::Document.new(
            source_type: "event",
            source_id: 1_i64,
            text: "Document with relationships",
            pair_id: 99_i64,
            parent_id: 88_i64
          ),
        ]

        service.index_batch(docs)

        # Join with sources table to get external IDs for pair and parent
        
result = service.db.query_one(
          "SELECT ps.external_int, prs.external_int
           FROM memo_chunks c
           LEFT JOIN memo_sources ps ON c.pair_id = ps.id
           LEFT JOIN memo_sources prs ON c.parent_id = prs.id
           LIMIT 1",
          as: {Int64?, Int64?}
        )
        result.should eq({99_i64, 88_i64})
      end
    end

    it "deduplicates shared content across documents" do
      with_test_service do |service|
        docs = [
          Memo::Document.new(source_type: "event", source_id: 1_i64, text: "Shared text"),
          Memo::Document.new(source_type: "event", source_id: 2_i64, text: "Shared text"),
        ]

        count = service.index_batch(docs)
        count.should eq(2)

        stats = service.stats
        stats.embeddings.should eq(1)  # Deduplicated
        stats.chunks.should eq(2)      # Two chunks
      end
    end
  end

  describe "#search" do
    it "searches and finds indexed documents" do
      with_test_service do |service|
        # Index a document
        service.index(
          source_type: "event",
          source_id: 1_i64,
          text: "The quick brown fox jumps over the lazy dog"
        )

        # Search for it (use min_score: 0.0 since mock provider uses hash-based embeddings)
        results = service.search(query: "fox jumps", limit: 5, min_score: 0.0)
        results.size.should be > 0
        results.first.source_type.should eq("event")
        results.first.source_id.should eq(1_i64)
      end
    end

    it "returns empty array when no matches" do
      with_test_service do |service|
        results = service.search(query: "nonexistent", limit: 5)
        results.should be_empty
      end
    end

    it "filters by source_type" do
      with_test_service do |service|
        # Index two different types
        service.index(source_type: "event", source_id: 1_i64, text: "Event document")
        service.index(source_type: "idea", source_id: 2_i64, text: "Idea document")

        # Search filtering by type
        results = service.search(query: "document", source_type: "event")
        results.all? { |r| r.source_type == "event" }.should be_true
      end
    end

    it "respects min_score threshold" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Test document")

        # High min_score should return no results
        results = service.search(query: "test", min_score: 0.99)
        results.should be_empty
      end
    end

    it "filters by like pattern" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Document about cats")
        service.index(source_type: "event", source_id: 2_i64, text: "Document about dogs")

        # Search with like filter
        results = service.search(query: "document", like: "%cats%", min_score: 0.0)
        results.size.should eq(1)
        results.first.source_id.should eq(1_i64)
      end
    end

    it "filters by multiple like patterns (AND)" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Document about cats and dogs")
        service.index(source_type: "event", source_id: 2_i64, text: "Document about cats only")
        service.index(source_type: "event", source_id: 3_i64, text: "Document about dogs only")

        # Search with multiple like patterns (AND)
        results = service.search(query: "document", like: ["%cats%", "%dogs%"], min_score: 0.0)
        results.size.should eq(1)
        results.first.source_id.should eq(1_i64)
      end
    end

    it "filters by FTS5 match query" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "The quick brown fox")
        service.index(source_type: "event", source_id: 2_i64, text: "The lazy dog sleeps")

        # Search with FTS5 match
        results = service.search(query: "animal", match: "fox", min_score: 0.0)
        results.size.should eq(1)
        results.first.source_id.should eq(1_i64)
      end
    end

    it "returns text when include_text is true" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "The quick brown fox")

        # Search with include_text
        results = service.search(query: "fox", include_text: true, min_score: 0.0)
        results.size.should be > 0
        results.first.text.should eq("The quick brown fox")
      end
    end

    it "returns nil text when include_text is false" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "The quick brown fox")

        # Search without include_text
        results = service.search(query: "fox", include_text: false, min_score: 0.0)
        results.size.should be > 0
        results.first.text.should be_nil
      end
    end
  end

  describe "#text_storage" do
    it "has text storage enabled by default" do
      with_test_service do |service|
        service.text_storage?.should be_true
      end
    end

    it "can be disabled with store_text: false" do
      with_test_db_path do |db_path|
        service = Memo::Service.new(
          db_path: db_path,
          service: "mock",
          store_text: false,
          chunking_max_tokens: 50
        )

        service.text_storage?.should be_false

        # Index should still work
        count = service.index(source_type: "event", source_id: 1_i64, text: "Test doc")
        count.should be > 0

        service.close
      end
    end

    it "stores text in the contents table" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Stored text content")

        # Verify text was stored, and the source points at it
        content = service.db.query_one?(
          "SELECT t.content FROM memo_sources s
           JOIN memo_contents t ON t.id = s.content_id
           WHERE s.source_type = ? AND s.external_int = ?",
          "event", 1_i64,
          as: String
        )
        content.should eq("Stored text content")
      end
    end

    it "stores a text two sources share once" do
      with_test_service do |service|
        # Index same text for two different sources
        service.index(source_type: "event", source_id: 1_i64, text: "Same text")
        service.index(source_type: "event", source_id: 2_i64, text: "Same text")

        count = service.db.scalar("SELECT COUNT(*) FROM memo_contents").as(Int64)
        count.should eq(1)
      end
    end

    it "overwrites text when re-indexing same source" do
      with_test_service do |service|
        # Index then re-index with different text
        service.index(source_type: "event", source_id: 1_i64, text: "Original text")
        service.index(source_type: "event", source_id: 1_i64, text: "Updated text")

        # Should still have one entry with updated content
        count = service.db.scalar("SELECT COUNT(*) FROM memo_contents").as(Int64)
        count.should eq(1)

        content = service.db.query_one?(
          "SELECT t.content FROM memo_sources s
           JOIN memo_contents t ON t.id = s.content_id
           WHERE s.source_type = ? AND s.external_int = ?",
          "event", 1_i64,
          as: String
        )
        content.should eq("Updated text")
      end
    end
  end

  describe "#mark_as_read" do
    it "increments read_count for chunks" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Test document")

        # Get chunk ID
        chunk_id = service.db.scalar("SELECT id FROM memo_chunks LIMIT 1").as(Int64)

        # Mark as read
        service.mark_as_read([chunk_id])

        # Verify read_count incremented
        read_count = service.db.scalar(
          "SELECT read_count FROM memo_chunks WHERE id = ?",
          chunk_id
        ).as(Int64)
        read_count.should eq(1)
      end
    end
  end

  describe "#stats" do
    it "returns zero counts for empty database" do
      with_test_service do |service|
        stats = service.stats
        stats.embeddings.should eq(0)
        stats.chunks.should eq(0)
        stats.sources.should eq(0)
      end
    end

    it "counts indexed content correctly" do
      with_test_service do |service|
        # Index 3 documents
        service.index(source_type: "event", source_id: 1_i64, text: "First document")
        service.index(source_type: "event", source_id: 2_i64, text: "Second document")
        service.index(source_type: "idea", source_id: 3_i64, text: "Third document")

        stats = service.stats
        stats.embeddings.should eq(3)
        stats.chunks.should eq(3)
        stats.sources.should eq(3)
      end
    end

    it "counts unique sources when same text is indexed multiple times" do
      with_test_service do |service|
        # Index same text for different sources (deduplication)
        service.index(source_type: "event", source_id: 1_i64, text: "Same text")
        service.index(source_type: "event", source_id: 2_i64, text: "Same text")

        stats = service.stats
        stats.embeddings.should eq(1)  # Deduplicated
        stats.chunks.should eq(2)      # Two chunks
        stats.sources.should eq(2)     # Two sources
      end
    end
  end

  describe "#delete" do
    it "deletes chunks for a source" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Document one")
        service.index(source_type: "event", source_id: 2_i64, text: "Document two")

        stats_before = service.stats
        stats_before.sources.should eq(2)

        # Delete source 1
        deleted = service.delete(source_id: 1_i64)
        deleted.should eq(1)

        stats_after = service.stats
        stats_after.sources.should eq(1)
        stats_after.chunks.should eq(1)
      end
    end

    it "cleans up orphaned embeddings" do
      with_test_service do |service|
        service.index(source_type: "event", source_id: 1_i64, text: "Unique document")

        stats_before = service.stats
        stats_before.embeddings.should eq(1)

        # Delete the only source referencing this embedding
        service.delete(source_id: 1_i64)

        stats_after = service.stats
        stats_after.embeddings.should eq(0)
      end
    end

    it "preserves shared embeddings" do
      with_test_service do |service|
        # Index same text for two sources
        service.index(source_type: "event", source_id: 1_i64, text: "Shared text")
        service.index(source_type: "event", source_id: 2_i64, text: "Shared text")

        stats_before = service.stats
        stats_before.embeddings.should eq(1)  # Deduplicated
        stats_before.chunks.should eq(2)

        # Delete one source
        service.delete(source_id: 1_i64)

        stats_after = service.stats
        stats_after.embeddings.should eq(1)  # Still referenced by source 2
        stats_after.chunks.should eq(1)
      end
    end

    it "returns 0 when source doesn't exist" do
      with_test_service do |service|
        deleted = service.delete(source_id: 999_i64)
        deleted.should eq(0)
      end
    end

    it "deletes only matching source_type when specified" do
      with_test_service do |service|
        # Index same source_id with different types
        service.index(source_type: "event", source_id: 1_i64, text: "Event document")
        service.index(source_type: "idea", source_id: 1_i64, text: "Idea document")

        stats_before = service.stats
        stats_before.chunks.should eq(2)

        # Delete only the event type
        deleted = service.delete(source_id: 1_i64, source_type: "event")
        deleted.should eq(1)

        stats_after = service.stats
        stats_after.chunks.should eq(1)

        # Verify the idea document remains
        results = service.search(query: "document", source_type: "idea", min_score: 0.0)
        results.size.should eq(1)
        results.first.source_type.should eq("idea")
      end
    end
  end
end
