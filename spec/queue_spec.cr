require "./spec_helper"

describe Memo::Service do
  describe "Queue Operations" do
    describe "#enqueue and #process_queue" do
      it "enqueues and processes a single document" do
        with_test_service do |service|
          service.enqueue(
            source_type: "event",
            source_id: 1_i64,
            text: "Queued document for embedding"
          )

          stats = service.queue_stats
          stats.pending.should eq(1)
          stats.failed.should eq(0)

          processed = service.process_queue
          processed.should be > 0

          stats = service.queue_stats
          stats.pending.should eq(0)
        end
      end

      it "enqueues with pair_id and parent_id" do
        with_test_service do |service|
          service.enqueue(
            source_type: "event",
            source_id: 1_i64,
            text: "Document with relationships",
            pair_id: 99_i64,
            parent_id: 88_i64
          )

          processed = service.process_queue
          processed.should be > 0

          # Verify relationships stored in chunks
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

      it "makes content searchable after processing" do
        with_test_service do |service|
          service.enqueue(
            source_type: "event",
            source_id: 1_i64,
            text: "The quick brown fox jumps over the lazy dog"
          )

          # Before processing, nothing to find
          results = service.search(query: "fox", min_score: 0.0)
          results.should be_empty

          service.process_queue

          # After processing, should be searchable
          results = service.search(query: "fox", min_score: 0.0)
          results.size.should be > 0
        end
      end

      it "updates queue item on re-enqueue" do
        with_test_service do |service|
          service.enqueue(source_type: "event", source_id: 1_i64, text: "Original")
          service.enqueue(source_type: "event", source_id: 1_i64, text: "Updated")

          # Should still be just one pending item (ON CONFLICT UPDATE)
          stats = service.queue_stats
          stats.pending.should eq(1)

          service.process_queue

          # Should have the updated text
          results = service.search(query: "Updated", include_text: true, min_score: 0.0)
          results.size.should be > 0
          results.first.text.should eq("Updated")
        end
      end
    end

    describe "#enqueue (Document)" do
      it "enqueues a Document struct" do
        with_test_service do |service|
          doc = Memo::Document.new(
            source_type: "event",
            source_id: 1_i64,
            text: "Document struct queued"
          )

          service.enqueue(doc)

          stats = service.queue_stats
          stats.pending.should eq(1)
        end
      end
    end

    describe "#enqueue_batch" do
      it "enqueues multiple documents" do
        with_test_service do |service|
          docs = [
            Memo::Document.new(source_type: "event", source_id: 1_i64, text: "First"),
            Memo::Document.new(source_type: "event", source_id: 2_i64, text: "Second"),
            Memo::Document.new(source_type: "event", source_id: 3_i64, text: "Third"),
          ]

          service.enqueue_batch(docs)

          stats = service.queue_stats
          stats.pending.should eq(3)

          processed = service.process_queue
          processed.should eq(3)

          stats = service.queue_stats
          stats.pending.should eq(0)
        end
      end

      it "skips empty array" do
        with_test_service do |service|
          service.enqueue_batch([] of Memo::Document)
          service.queue_stats.pending.should eq(0)
        end
      end
    end

    describe "#queue_stats" do
      it "returns zeros for empty queue" do
        with_test_service do |service|
          stats = service.queue_stats
          stats.pending.should eq(0)
          stats.failed.should eq(0)
        end
      end

      it "tracks pending items" do
        with_test_service do |service|
          service.enqueue(source_type: "event", source_id: 1_i64, text: "Pending item")
          service.enqueue(source_type: "event", source_id: 2_i64, text: "Another pending")

          stats = service.queue_stats
          stats.pending.should eq(2)
          stats.failed.should eq(0)
        end
      end
    end

    describe "#clear_completed_queue" do
      it "removes processed items" do
        with_test_service do |service|
          service.enqueue(source_type: "event", source_id: 1_i64, text: "Will be processed")
          service.process_queue

          cleared = service.clear_completed_queue
          cleared.should eq(1)
        end
      end

      it "does not remove pending items" do
        with_test_service do |service|
          service.enqueue(source_type: "event", source_id: 1_i64, text: "Still pending")

          cleared = service.clear_completed_queue
          cleared.should eq(0)

          service.queue_stats.pending.should eq(1)
        end
      end
    end

    describe "#clear_queue" do
      it "removes all items regardless of status" do
        with_test_service do |service|
          service.enqueue(source_type: "event", source_id: 1_i64, text: "Pending")
          service.enqueue(source_type: "event", source_id: 2_i64, text: "Also pending")
          # Process one to get mixed statuses
          service.process_queue
          service.enqueue(source_type: "event", source_id: 3_i64, text: "New pending")

          cleared = service.clear_queue
          cleared.should be > 0

          stats = service.queue_stats
          stats.pending.should eq(0)
          stats.failed.should eq(0)
        end
      end

      it "returns 0 for empty queue" do
        with_test_service do |service|
          service.clear_queue.should eq(0)
        end
      end
    end

    describe "text storage on enqueue" do
      it "stores text immediately when enqueued (before processing)" do
        with_test_service do |service|
          service.enqueue(source_type: "event", source_id: 1_i64, text: "Available before embedding")

          # Text should be in the texts table even before process_queue
          content = service.db.query_one?(
            "SELECT t.content FROM memo_sources s
             JOIN memo_contents t ON t.id = s.content_id
             WHERE s.source_type = ? AND s.external_int = ?",
            "event", 1_i64,
            as: String
          )
          content.should eq("Available before embedding")
        end
      end
    end
  end
end
