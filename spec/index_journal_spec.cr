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

# The last journal entry the service's saved index includes
private def saved_seq(service : Memo::Service) : Int64
  File.read(Memo::USearchIndex.checkpoint_path(service.index_path)).split.first.to_i64
end

private def open_in(db_path : String, index_dir : String) : Memo::Service
  Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50, index_dir: index_dir)
end

private def with_index_dir(&)
  dir = File.tempname("memo_index")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Move the service's index file to where earlier versions kept it in
# `index_dir`, with a checkpoint that doesn't say whose it is. Returns the
# path.
private def move_to_legacy_name(service : Memo::Service, index_dir : String) : String
  legacy = Memo::USearchIndex.index_path_in_dir(index_dir, service.service_format, service.service_model, service.dimensions)
  checkpoint = Memo::USearchIndex.checkpoint_path(service.index_path)
  File.write(Memo::USearchIndex.checkpoint_path(legacy), File.read(checkpoint).split.first)
  File.delete(checkpoint)
  File.rename(service.index_path, legacy)
  legacy
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

      service.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      service.save_index
      first = saved_seq(service)
      saved_at = File.info(service.index_path).modification_time

      service.save_index # nothing changed: no write
      File.info(service.index_path).modification_time.should eq saved_at

      service.index(source_type: "doc", source_id: 2_i64, text: "tiny haunted robot")
      service.save_index
      saved_seq(service).should be > first
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
      saved_seq(service).should be > 0
      service.close
    end
  end

  it "saves when due, not on every call" do
    with_test_db_path do |db_path|
      # The interval runs from the start of Service.new: long enough that
      # opening and indexing finish within it on a slow CI runner
      service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50,
        index_save_changes: 100, index_save_interval: 300.milliseconds)
      service.index(source_type: "doc", source_id: 1_i64, text: "document 1")
      service.save_index_if_due
      File.exists?(service.index_path).should be_false

      sleep 310.milliseconds # one change, unsaved past the interval
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

  it "applies removals another service logged while it was open, before saving past them" do
    with_test_db_path do |db_path|
      setup = open_service(db_path)
      setup.create_service(name: "mock-b", format: "mock", model: "mock-b", dimensions: 8, max_tokens: 100)
      setup.close

      a = open_service(db_path)
      b = open_service(db_path, "mock-b")
      b.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      a.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      a.index(source_type: "doc", source_id: 9_i64, text: "a quiet morning at the market") # so no id is reused
      orphaned = b.db.scalar("SELECT rowid FROM memo_embeddings WHERE service_id = ?", b.service_id).as(Int64)

      # A removes the content for both while B is open; B then saves
      a.delete(1_i64, "doc")
      b.index(source_type: "doc", source_id: 2_i64, text: "tiny haunted robot")
      b.save_index
      b.usearch_index.contains?(orphaned.to_u64).should be_false
      b.close

      b = open_service(db_path, "mock-b")
      b.usearch_index.contains?(orphaned.to_u64).should be_false
      b.usearch_index.size.should eq 1
      b.close
      a.close
    end
  end

  it "replays a removal as one, after another service's embedding reuses its id" do
    with_test_db_path do |db_path|
      setup = open_service(db_path)
      setup.create_service(name: "mock-b", format: "mock", model: "mock-b", dimensions: 8, max_tokens: 100)
      setup.close

      b = open_service(db_path, "mock-b")
      b.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      removed = b.db.scalar("SELECT rowid FROM memo_embeddings WHERE service_id = ?", b.service_id).as(Int64)
      b.close

      # A removes the content for both, then stores an embedding that
      # SQLite gives the freed id
      a = open_service(db_path)
      a.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
      a.delete(1_i64, "doc")
      a.index(source_type: "doc", source_id: 2_i64, text: "tiny haunted robot")
      a.db.scalar("SELECT service_id FROM memo_embeddings WHERE rowid = ?", removed).should eq a.service_id
      a.close

      b = open_service(db_path, "mock-b")
      b.usearch_index.contains?(removed.to_u64).should be_false
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

  it "keeps databases sharing an index_dir apart" do
    with_index_dir do |dir|
      with_test_db_path do |a_path|
        with_test_db_path do |b_path|
          a = open_in(a_path, dir)
          b = open_in(b_path, dir)
          a.index_path.should_not eq b.index_path
          a.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla")
          b.index(source_type: "doc", source_id: 1_i64, text: "grape ape")
          a.close
          b.close

          a = open_in(a_path, dir)
          a.index_recovery.rebuilt.should eq 0
          a.search(query: "purple gorilla", min_score: 0.99).size.should eq 1
          a.close
        end
      end
    end
  end

  it "rebuilds an index file another database saved" do
    with_test_db_path do |a_path|
      with_test_db_path do |b_path|
        a = open_service(a_path)
        a.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla")
        a.close
        b = open_service(b_path)
        b.index(source_type: "doc", source_id: 1_i64, text: "grape ape")
        b.close

        # As a shared index_dir could leave it
        File.copy(b.index_path, a.index_path)
        File.copy(Memo::USearchIndex.checkpoint_path(b.index_path), Memo::USearchIndex.checkpoint_path(a.index_path))

        a = open_service(a_path)
        a.index_recovery.rebuilt.should eq 1
        a.search(query: "purple gorilla", min_score: 0.99).size.should eq 1
        a.close
      end
    end
  end

  it "adopts its index file from the name earlier versions gave it in an index_dir" do
    with_index_dir do |dir|
      with_test_db_path do |db_path|
        memo = open_in(db_path, dir)
        memo.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla")
        memo.close
        legacy = move_to_legacy_name(memo, dir)

        memo = open_in(db_path, dir)
        memo.index_recovery.rebuilt.should eq 0
        File.exists?(legacy).should be_false
        memo.search(query: "purple gorilla", min_score: 0.99).size.should eq 1
        memo.close
      end
    end
  end

  it "leaves another database's file at that earlier name alone" do
    with_index_dir do |dir|
      with_index_dir do |other_dir|
        with_test_db_path do |a_path|
          with_test_db_path do |b_path|
            a = open_in(a_path, dir)
            a.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla")
            a.close
            Memo::USearchIndex.delete_file(a.index_path)

            b = open_in(b_path, other_dir)
            b.index(source_type: "doc", source_id: 1_i64, text: "grape ape")
            b.close
            legacy = move_to_legacy_name(b, dir)

            a = open_in(a_path, dir)
            a.index_recovery.rebuilt.should eq 1
            File.exists?(legacy).should be_true
            a.search(query: "purple gorilla", min_score: 0.99).size.should eq 1
            a.close
          end
        end
      end
    end
  end

  it "records whose index a checkpoint is" do
    with_test_db_path do |db_path|
      memo = open_service(db_path)
      memo.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla")
      database_id = Memo::Database.id(memo.db)
      memo.close

      File.read(Memo::USearchIndex.checkpoint_path(memo.index_path)).split[1..]
        .should eq [database_id, memo.service_id.to_s]
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
