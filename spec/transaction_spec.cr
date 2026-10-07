require "./spec_helper"

describe Memo::Database do
  describe ".transaction" do
    it "rolls back statements run on the yielded connection" do
      with_test_db do |db|
        expect_raises(Exception, "boom") do
          Memo::Database.transaction(db) do |cnn|
            Memo::SourceRegistry.create(cnn, "doc")
            raise "boom"
          end
        end

        db.scalar("SELECT COUNT(*) FROM memo_sources").as(Int64).should eq 0
      end
    end

    it "commits statements run on the yielded connection" do
      with_test_db do |db|
        Memo::Database.transaction(db) do |cnn|
          Memo::SourceRegistry.create(cnn, "doc")
        end

        db.scalar("SELECT COUNT(*) FROM memo_sources").as(Int64).should eq 1
      end
    end

    it "joins an open transaction when given its connection" do
      with_test_db do |db|
        expect_raises(Exception, "boom") do
          Memo::Database.transaction(db) do |outer|
            Memo::Database.transaction(outer) do |inner|
              inner.should be(outer)
              Memo::SourceRegistry.create(inner, "doc")
            end
            raise "boom"
          end
        end

        db.scalar("SELECT COUNT(*) FROM memo_sources").as(Int64).should eq 0
      end
    end
  end
end

describe Memo::Service do
  describe "transactions" do
    it "waits for another process's write lock instead of failing" do
      sqlite3 = Process.find_executable("sqlite3")
      pending!("needs the sqlite3 command") unless sqlite3
      with_test_db_path do |db_path|
        service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
        service.db.exec("PRAGMA journal_mode=WAL") # as DataDungeon's databases are
        service.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")

        # Another process holds the write lock for half a second
        script = "BEGIN IMMEDIATE;\nINSERT INTO memo_meta (key, value) VALUES ('probe', '1');\n.shell sleep 0.5\nCOMMIT;\n"
        holder = Process.new(sqlite3, [db_path], input: IO::Memory.new(script), output: Process::Redirect::Close)
        sleep 150.milliseconds

        # A write transaction with no retry around it: it must wait, not fail
        service.delete(1_i64, "doc").should eq 1
        holder.wait.success?.should be_true
        service.close
      end
    end

    it "leaves chunks and vectors intact when a reindex fails partway" do
      with_test_service do |service|
        service.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
        chunks_before = service.stats.chunks

        expect_raises(Exception, "lookup failed") do
          service.reindex("doc") { |_id| raise "lookup failed" }
        end

        service.stats.chunks.should eq chunks_before
        results = service.search(query: "purple gorilla in a top hat", min_score: 0.0)
        results.map(&.source_id).should contain(1_i64)
      end
    end

    it "indexes a new document whose rowid was freed by a delete the index file never saw" do
      with_test_db_path do |db_path|
        open = -> { Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50) }

        first = open.call
        first.index(source_type: "doc", source_id: 1_i64, text: "purple gorilla in a top hat")
        first.index(source_type: "doc", source_id: 2_i64, text: "grape ape with a monocle")
        first.close

        # Delete the newest embedding, then stop without saving the index
        # (as in a crash). The saved index still holds the deleted vector.
        second = open.call
        second.delete(2_i64, "doc")
        second.db.close
        second.@index_lock.close # a crash ends the process, releasing its lock

        # SQLite hands the freed rowid to the next embedding.
        third = open.call
        begin
          third.index(source_type: "doc", source_id: 3_i64, text: "tiny haunted robot").should eq 1
          results = third.search(query: "tiny haunted robot", min_score: 0.0)
          results.first.source_id.should eq 3_i64
        ensure
          third.close
        end
      end
    end
  end
end
