require "./spec_helper"

# Lets a spec make the next index update fail, as a USearch error would
class Memo::USearchIndex::Pending
  class_property fail_next = false

  def apply(index : USearch::Index)
    if Pending.fail_next
      Pending.fail_next = false
      raise "simulated index failure"
    end
    previous_def
  end
end

private def open_service(db_path : String, service : String = "mock") : Memo::Service
  Memo::Service.new(db_path: db_path, service: service, chunking_max_tokens: 50)
end

# Stop without saving the index, as a crash would. A crash also ends the
# process, which releases its index lock.
private def crash(service : Memo::Service)
  service.db.close
  service.@index_lock.close
end

private def count(service : Memo::Service, table : String) : Int64
  service.db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64)
end

private def finds?(service : Memo::Service, text : String, source_id : Int64) : Bool
  service.search(query: text, min_score: 0.0).any? { |r| r.source_id == source_id }
end

describe Memo::Storage do
  describe ".encode_vector" do
    it "round-trips values a half float represents exactly" do
      vector = [0.0, 1.0, -2.5, 0.125, 65504.0, -6.103515625e-5, 5.960464477539063e-8] # incl. smallest normal and subnormal
      Memo::Storage.decode_vector(Memo::Storage.encode_vector(vector)).should eq vector
    end

    it "rounds other values to the nearest half float" do
      decoded = Memo::Storage.decode_vector(Memo::Storage.encode_vector([0.1]))
      decoded.first.should eq 0.0999755859375
    end

    it "doesn't clamp values outside -1..1" do
      Memo::Storage.decode_vector(Memo::Storage.encode_vector([3.0])).should eq [3.0]
    end
  end
end

describe Memo::IndexJournal do
  it "stores a vector for each embedding and removes it with the embedding" do
    with_test_db_path do |db_path|
      service = open_service(db_path)
      service.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      count(service, "memo_vectors").should eq count(service, "memo_embeddings")
      count(service, "memo_vectors").should be > 0

      service.delete(1_i64, "doc")
      count(service, "memo_vectors").should eq 0
      service.close
    end
  end

  it "saves only when the index has changed" do
    with_test_db_path do |db_path|
      service = open_service(db_path)
      checkpoint_path = Memo::USearchIndex.checkpoint_path(service.index_path)

      service.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      service.save_index
      first = File.read(checkpoint_path)
      saved_at = File.info(service.index_path).modification_time

      service.save_index # nothing changed: no write
      File.info(service.index_path).modification_time.should eq saved_at

      service.index(source_type: "doc", source_id: 2_i64, text: "tiny haunted robot")
      service.save_index
      File.read(checkpoint_path).to_i64.should be > first.to_i64
      service.close
    end
  end

  it "saves on its own once enough changes are unsaved" do
    with_test_db_path do |db_path|
      service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50,
        index_save_changes: 3, index_save_interval: 1.hour)
      2.times { |i| service.index(source_type: "doc", source_id: i.to_i64, text: "document #{i}") }
      File.exists?(service.index_path).should be_false

      service.index(source_type: "doc", source_id: 2_i64, text: "document 2")
      20.times { break if File.exists?(service.index_path); sleep 10.milliseconds } # saves in a separate fiber
      File.exists?(service.index_path).should be_true
      File.read(Memo::USearchIndex.checkpoint_path(service.index_path)).to_i64.should be > 0
      service.close
    end
  end

  it "saves when due, not on every call" do
    with_test_db_path do |db_path|
      service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50,
        index_save_changes: 100, index_save_interval: 50.milliseconds)
      service.index(source_type: "doc", source_id: 1_i64, text: "document 1")
      service.save_index_if_due
      File.exists?(service.index_path).should be_false

      sleep 60.milliseconds # one change, unsaved past the interval
      service.save_index_if_due
      File.exists?(service.index_path).should be_true
      service.close
    end
  end

  it "catches up after a failed index update and keeps pruning the journal" do
    with_test_db_path do |db_path|
      service = open_service(db_path)
      service.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      Memo::USearchIndex::Pending.fail_next = true
      service.index(source_type: "doc", source_id: 2_i64, text: "tiny haunted robot") # committed, not indexed

      service.save_index
      finds?(service, "tiny haunted robot", 2_i64).should be_true
      count(service, "memo_index_log").should eq 0 # checkpointed and pruned

      service.index(source_type: "doc", source_id: 3_i64, text: "regal sleepy dragon")
      service.save_index
      count(service, "memo_index_log").should eq 0 # and still does later
      service.close
    ensure
      Memo::USearchIndex::Pending.fail_next = false
    end
  end

  it "replays nothing after a clean restart" do
    with_test_db_path do |db_path|
      first = open_service(db_path)
      first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      first.close

      second = open_service(db_path)
      second.index_recovery.replayed.should eq 0
      second.index_recovery.rebuilt.should eq 0
      finds?(second, "purple gorilla in a top hat", 1_i64).should be_true
      second.close
    end
  end

  it "replays additions and deletions made after the last save" do
    with_test_db_path do |db_path|
      first = open_service(db_path)
      first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      first.close

      second = open_service(db_path)
      second.index(source_type: "doc", source_id: 2_i64, text: "tiny haunted robot")
      second.delete(1_i64, "doc")
      crash(second)

      third = open_service(db_path)
      third.index_recovery.replayed.should eq 2
      third.usearch_index.size.should eq count(third, "memo_embeddings")
      finds?(third, "tiny haunted robot", 2_i64).should be_true
      third.close

      # Recovery checkpointed, so the next open has nothing to replay
      fourth = open_service(db_path)
      fourth.index_recovery.replayed.should eq 0
      fourth.close
    end
  end

  it "rebuilds a missing index file from stored vectors" do
    with_test_db_path do |db_path|
      first = open_service(db_path)
      first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      first.index(source_type: "doc", source_id: 2_i64, text: "tiny haunted robot")
      index_path = first.index_path
      first.close
      File.delete(index_path)

      second = open_service(db_path)
      second.index_recovery.rebuilt.should eq 2
      finds?(second, "tiny haunted robot", 2_i64).should be_true
      second.close
    end
  end

  it "rebuilds an index file that can't be loaded" do
    with_test_db_path do |db_path|
      first = open_service(db_path)
      first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      index_path = first.index_path
      first.close
      File.write(index_path, "not an index")

      second = open_service(db_path)
      second.index_recovery.rebuilt.should eq 1
      finds?(second, "purple gorilla in a top hat", 1_i64).should be_true
      second.close
    end
  end

  it "rebuilds an index file older than the pruned log" do
    with_test_db_path do |db_path|
      first = open_service(db_path)
      first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      index_path = first.index_path
      checkpoint_path = Memo::USearchIndex.checkpoint_path(index_path)
      first.close
      old_index = File.read(index_path)
      old_checkpoint = File.read(checkpoint_path)

      second = open_service(db_path)
      second.index(source_type: "doc", source_id: 2_i64, text: "tiny haunted robot")
      second.close # prunes the log past the old checkpoint

      File.write(index_path, old_index)
      File.write(checkpoint_path, old_checkpoint)

      third = open_service(db_path)
      third.index_recovery.rebuilt.should eq 2
      finds?(third, "tiny haunted robot", 2_i64).should be_true
      third.close
    end
  end

  it "backfills vectors for embeddings stored before memo kept them" do
    with_test_db_path do |db_path|
      first = open_service(db_path)
      first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      index_path = first.index_path
      first.db.exec("DELETE FROM memo_vectors")
      first.db.exec("DELETE FROM memo_index_state")
      first.close

      second = open_service(db_path)
      second.index_recovery.missing.should eq 0
      count(second, "memo_vectors").should eq 1
      second.close

      # The copied vectors are enough to rebuild from
      File.delete(index_path)
      third = open_service(db_path)
      third.index_recovery.rebuilt.should eq 1
      finds?(third, "purple gorilla in a top hat", 1_i64).should be_true
      third.close
    end
  end

  it "reports old embeddings with no vector anywhere, and repairs them when re-indexed" do
    with_test_db_path do |db_path|
      first = open_service(db_path)
      # Two sources share the text, so the embedding outlives either one's chunks
      first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      first.index(source_type: "doc", source_id: 2_i64, text: "purple gorilla in a top hat")
      index_path = first.index_path
      first.db.exec("DELETE FROM memo_vectors")
      first.db.exec("DELETE FROM memo_index_state")
      first.close
      File.delete(index_path)

      second = open_service(db_path)
      second.index_recovery.missing.should eq 1
      finds?(second, "purple gorilla in a top hat", 1_i64).should be_false

      second.enqueue(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      second.process_queue
      count(second, "memo_vectors").should eq 1
      finds?(second, "purple gorilla in a top hat", 1_i64).should be_true
      second.close
    end
  end

  it "logs removals for other services sharing an embedding's content" do
    with_test_db_path do |db_path|
      setup = open_service(db_path)
      setup.create_service(name: "mock-b", format: "mock", model: "mock-b", dimensions: 8, max_tokens: 100)
      setup.close

      b = open_service(db_path, "mock-b")
      b.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      b.close

      # Deleting through service A orphans the content for both services
      a = open_service(db_path)
      a.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      a.delete(1_i64, "doc")
      a.close

      b = open_service(db_path, "mock-b")
      b.index_recovery.replayed.should eq 1
      b.usearch_index.size.should eq 0
      b.close
    end
  end

  it "removes a deleted service's vectors and journal" do
    with_test_db_path do |db_path|
      setup = open_service(db_path)
      setup.create_service(name: "mock-b", format: "mock", model: "mock-b", dimensions: 8, max_tokens: 100)
      setup.close

      b = open_service(db_path, "mock-b")
      b.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      b.close

      a = open_service(db_path)
      a.delete_service("mock-b", force: true).should be_true
      count(a, "memo_vectors").should eq 0
      count(a, "memo_index_log").should eq 0
      count(a, "memo_index_state WHERE service_id <> #{a.service_id}").should eq 0
      a.close
    end
  end
end

describe Memo::USearchIndex do
  it "refuses a second open of an index that is already open" do
    with_test_db_path do |db_path|
      first = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
      expect_raises(Memo::USearchIndex::InUse, /already open by process #{Process.pid}/) do
        Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
      end

      first.close
      second = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
      second.close
    end
  end

  it "holds a lock other processes see, until close" do
    flock = Process.find_executable("flock")
    pending!("needs the flock command (util-linux)") unless flock
    with_test_db_path do |db_path|
      service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
      lock_path = "#{service.index_path}.lock"
      Process.run(flock, ["-n", lock_path, "true"]).success?.should be_false # held

      service.close
      Process.run(flock, ["-n", lock_path, "true"]).success?.should be_true # released
    end
  end
end
