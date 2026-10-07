require "./spec_helper"
require "../src/arcana/namespaces"

describe Memo::Namespaces do
  it "opens a namespace once when requests arrive while it is still opening" do
    with_test_db_path do |db_path|
      # Store enough vectors that rebuilding the index yields to other fibers
      setup = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
      40.times { |i| setup.index(source_type: "doc", source_id: i.to_i64, text: "document number #{i}") }
      index_path = setup.index_path
      setup.close
      File.delete(index_path)

      namespaces = Memo::Namespaces.new
      namespaces.register(Memo::Namespaces::Config.new(ns: "a", db: db_path, service: "mock", chunking_max_tokens: 50))

      opened = Channel(Memo::Service).new
      3.times { spawn { opened.send(namespaces.get("a")) } }
      services = Array.new(3) { opened.receive }

      services.map(&.object_id).uniq.size.should eq 1
      services.first.index_recovery.rebuilt.should eq 40
      namespaces.close_all
    end
  end

  it "waits for an open in progress before closing" do
    with_test_db_path do |db_path|
      setup = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
      40.times { |i| setup.index(source_type: "doc", source_id: i.to_i64, text: "document number #{i}") }
      index_path = setup.index_path
      setup.close
      File.delete(index_path)

      namespaces = Memo::Namespaces.new
      namespaces.register(Memo::Namespaces::Config.new(ns: "a", db: db_path, service: "mock", chunking_max_tokens: 50))

      opened = Channel(Nil).new
      spawn do
        namespaces.get("a")
        opened.send(nil)
      end
      Fiber.yield # the open is now rebuilding

      namespaces.close("a").should be_true
      opened.receive
      namespaces.list.should eq [{"a", false}]
    end
  end

  it "lets requests already using a namespace finish before closing it" do
    with_test_db_path do |db_path|
      namespaces = Memo::Namespaces.new
      namespaces.register(Memo::Namespaces::Config.new(ns: "a", db: db_path, service: "mock", chunking_max_tokens: 50))
      namespaces.get("a").index(source_type: "doc", source_id: 1_i64, text: "purple gorilla")

      outcome = Channel(Int32 | Exception).new(1)
      spawn do
        namespaces.use("a") do |memo|
          sleep 100.milliseconds # e.g. waiting on an embedding call
          outcome.send(memo.search(query: "purple gorilla", min_score: 0.0).size)
        end
      rescue ex
        outcome.send(ex)
      end
      Fiber.yield # the request is now using the service

      namespaces.close("a").should be_true
      outcome.receive.should eq 1 # it finished, rather than finding the index closed
    end
  end
end
