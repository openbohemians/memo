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

  it "opens only configured namespaces unless allowed to open others" do
    with_test_db_path do |db_path|
      namespaces = Memo::Namespaces.new
      config = Memo::Namespaces::Config.new(ns: "a", db: db_path, service: "mock")
      expect_raises(Exception, /isn't configured/) { namespaces.open(config) }
      namespaces.list.should be_empty

      namespaces.allow_open = true
      namespaces.open(config).should be namespaces.get("a")
      namespaces.close_all
    end
  end

  it "keeps a registered namespace's settings when it's opened again" do
    with_test_db_path do |db_path|
      with_test_db_path do |other_path|
        namespaces = Memo::Namespaces.new
        namespaces.allow_open = true
        namespaces.register(Memo::Namespaces::Config.new(ns: "a", db: db_path, service: "mock"))

        namespaces.open(Memo::Namespaces::Config.new(ns: "a", db: db_path, service: "mock")).db_path.should eq db_path
        expect_raises(Exception, /already registered with another database/) do
          namespaces.open(Memo::Namespaces::Config.new(ns: "a", db: other_path, service: "mock"))
        end
        namespaces.close("a")
        namespaces.get("a").db_path.should eq db_path # reopens with its own settings
        namespaces.close_all
      end
    end
  end

  it "limits the default chunk size only for the mock service" do
    with_test_db_path do |a_path|
      with_test_db_path do |b_path|
        with_test_db_path do |c_path|
          namespaces = Memo::Namespaces.new
          namespaces.register(Memo::Namespaces::Config.new(ns: "by-format", db: a_path, format: "openai",
            model: "text-embedding-3-small", api_key: "sk-test"))
          namespaces.register(Memo::Namespaces::Config.new(ns: "default", db: b_path, api_key: "sk-test"))
          namespaces.register(Memo::Namespaces::Config.new(ns: "mock", db: c_path, service: "mock"))

          namespaces.get("by-format").chunking_config.max_tokens.should eq 2000
          namespaces.get("default").chunking_config.max_tokens.should eq 2000
          namespaces.get("mock").chunking_config.max_tokens.should eq 100
          namespaces.close_all
        end
      end
    end
  end

  it "gives the server's API key only to namespaces from the config file" do
    with_test_db_path do |db_path|
      with_test_db_path do |other_path|
        config_path = File.tempname("namespaces", ".yaml")
        File.write(config_path, "namespaces:\n  - ns: configured\n    db: #{db_path}\n    service: openai\n")
        previous = ENV["MEMO_API_KEY"]?
        ENV["MEMO_API_KEY"] = "sk-server"
        begin
          namespaces = Memo::Namespaces.new
          namespaces.load_config(config_path)
          namespaces.get("configured").provider.as(Memo::Providers::OpenAI).api_key.should eq "sk-server"

          namespaces.allow_open = true
          expect_raises(ArgumentError, /api_key required/) do
            namespaces.open(Memo::Namespaces::Config.new(ns: "opened", db: other_path, service: "openai"))
          end
          namespaces.list.should eq [{"configured", true}] # dropped, so a corrected open can follow

          opened = namespaces.open(Memo::Namespaces::Config.new(ns: "opened", db: other_path, service: "openai", api_key: "sk-client"))
          opened.provider.as(Memo::Providers::OpenAI).api_key.should eq "sk-client"
          namespaces.close_all
        ensure
          ENV["MEMO_API_KEY"] = previous
          File.delete(config_path)
        end
      end
    end
  end
end
