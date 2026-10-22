require "./spec_helper"
require "../src/arcana/service"

private def request(handler : Memo::ArcanaService, **data) : JSON::Any
  handler.handle(JSON.parse(data.to_json))
end

describe Memo::ArcanaService do
  it "bounds a search's limit" do
    with_test_db_path do |db_path|
      namespaces = Memo::Namespaces.new
      namespaces.register(Memo::Namespaces::Config.new(ns: "a", db: db_path, service: "mock"))
      handler = Memo::ArcanaService.new(namespaces)
      request(handler, action: "index", ns: "a", source_type: "doc", source_id: 1, text: "purple gorilla")

      reply = request(handler, action: "search", ns: "a", query: "purple gorilla", min_score: -1.0, limit: 1_000_000_000_000)
      reply["results"].as_a.size.should eq 1
      expect_raises(ArgumentError, /limit must be at least 1/) do
        request(handler, action: "search", ns: "a", query: "purple gorilla", limit: 0)
      end
      namespaces.close_all
    end
  end

  it "opens over the bus only what's configured, unless allowed" do
    with_test_db_path do |db_path|
      with_test_db_path do |other_path|
        namespaces = Memo::Namespaces.new
        namespaces.register(Memo::Namespaces::Config.new(ns: "a", db: db_path, service: "mock"))
        handler = Memo::ArcanaService.new(namespaces)

        request(handler, action: "open", ns: "a", db: db_path)["ok"].as_bool.should be_true
        expect_raises(Exception, /already registered with another database/) do
          request(handler, action: "open", ns: "a", db: other_path)
        end
        expect_raises(Exception, /isn't configured/) do
          request(handler, action: "open", ns: "b", db: other_path, service: "mock")
        end
        namespaces.list.map(&.[0]).should eq ["a"]
        namespaces.close_all
      end
    end
  end
end
