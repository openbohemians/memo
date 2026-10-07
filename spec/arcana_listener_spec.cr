require "./spec_helper"
require "arcana"
require "../src/arcana/listener"

Memo::BusLog.output = IO::Memory.new

# A private Arcana bus with a fake `openai:embed` service (answers after
# 200 ms) and a memo listener serving one namespace that embeds over it.
private class TestBus
  getter tester : Arcana::Client
  @port : Int32
  @server : Arcana::Server
  @embed : Arcana::Client
  @namespaces : Memo::Namespaces
  @memo : Arcana::Client

  def initialize(db_path : String, max_concurrency = 32, max_waiting = 256)
    @port = free_port
    @server = Arcana::Server.new(Arcana::Bus.new, Arcana::Directory.new, host: "127.0.0.1", port: @port)
    @server.start_in_background

    @embed = connect("openai:embed")
    @embed.on_message do |envelope|
      spawn do
        sleep 200.milliseconds
        texts = (envelope.payload["data"]? || envelope.payload)["texts"].as_a
        vectors = texts.map do |text|
          rng = Random.new(text.as_s.hash)
          JSON::Any.new(Array.new(1536) { JSON::Any.new(rng.next_float - 0.5) })
        end
        data = JSON::Any.new({"embeddings" => JSON::Any.new(vectors), "total_tokens" => JSON::Any.new(texts.size.to_i64)})
        @embed.send(envelope.reply(from: "openai:embed", payload: Arcana::Protocol.result(data)))
      end
    end

    @namespaces = Memo::Namespaces.new
    @namespaces.register(Memo::Namespaces::Config.new(ns: "game", db: db_path, service: "openai-bus"))
    @memo = connect(Memo::ArcanaListener::ADDRESS)
    Memo::Providers::Bus.client = @memo
    Memo::ArcanaListener.new(@memo, @namespaces, max_concurrency, max_waiting).listen

    @tester = connect("tester", listed: false)
    sleep 100.milliseconds # let every client's join reach the bus
  end

  # Send a request to memo and wait for its reply (nil on timeout)
  def ask(data : Hash(String, JSON::Any), timeout = 10.seconds) : Arcana::Envelope?
    send_to_memo(Arcana::Protocol.request(JSON::Any.new(data)), timeout)
  end

  def send_to_memo(payload : JSON::Any, timeout : Time::Span) : Arcana::Envelope?
    envelope = Arcana::Envelope.new(from: "tester", to: Memo::ArcanaListener::ADDRESS, subject: "test",
      payload: payload, correlation_id: Random::Secure.hex(8))
    @tester.request(envelope, timeout: timeout)
  end

  def close
    @namespaces.close_all
    Memo::Providers::Bus.client = nil
    {@tester, @memo, @embed}.each(&.close)
    @server.stop
  end

  private def connect(address : String, listed = true) : Arcana::Client
    client = Arcana::Client.new(url: "ws://127.0.0.1:#{@port}/bus", address: address, listed: listed)
    spawn { client.connect }
    until client.connected?
      sleep 10.milliseconds
    end
    client
  end

  private def free_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.port.tap { server.close }
  end
end

private def with_test_bus(max_concurrency = 32, max_waiting = 256, &)
  with_test_db_path do |db_path|
    bus = TestBus.new(db_path, max_concurrency, max_waiting)
    begin
      yield bus
    ensure
      bus.close
    end
  end
end

private def search(query : String) : Hash(String, JSON::Any)
  {"action" => JSON::Any.new("search"), "ns" => JSON::Any.new("game"),
   "query" => JSON::Any.new(query), "min_score" => JSON::Any.new(-1.0)}
end

describe Memo::ArcanaListener do
  it "answers requests concurrently, including ones that embed over the bus" do
    with_test_bus do |bus|
      replies = Channel(Arcana::Envelope?).new
      started = Time.instant
      5.times { |i| spawn { replies.send(bus.ask(search("query #{i}"))) } }
      statuses = Array.new(5) { replies.receive.try { |r| Arcana::Protocol.status(r.payload) } }

      statuses.should eq Array.new(5, "result")
      # Each search waits 200 ms for its embedding: concurrently that's
      # ~0.2 s; one at a time it would be 1 s or more
      (Time.instant - started).should be < 800.milliseconds
    end
  end

  it "indexes and finds a document" do
    with_test_bus do |bus|
      index = {"action" => JSON::Any.new("index"), "ns" => JSON::Any.new("game"), "source_type" => JSON::Any.new("doc"),
               "source_id" => JSON::Any.new(1_i64), "text" => JSON::Any.new("purple gorilla in a top hat")}
      bus.ask(index).try { |r| Arcana::Protocol.status(r.payload) }.should eq "result"

      reply = bus.ask(search("purple gorilla in a top hat")).not_nil!
      results = Arcana::Protocol.data(reply.payload).not_nil!["results"].as_a
      results.first["source_id"].as_i64.should eq 1
    end
  end

  it "ignores replies instead of answering them" do
    with_test_bus do |bus|
      stray = Arcana::Protocol.result(JSON::Any.new({"embeddings" => JSON::Any.new([] of JSON::Any)}))
      bus.send_to_memo(stray, timeout: 500.milliseconds).should be_nil
    end
  end

  it "answers busy instead of queueing requests without limit" do
    with_test_bus(max_concurrency: 1, max_waiting: 2) do |bus|
      replies = Channel(Arcana::Envelope?).new
      6.times { |i| spawn { replies.send(bus.ask(search("query #{i}"))) } }
      payloads = Array.new(6) { replies.receive.not_nil!.payload }

      busy = payloads.count { |p| p["code"]?.try(&.as_s) == "busy" }
      answered = payloads.count { |p| Arcana::Protocol.status(p) == "result" }
      busy.should be >= 1
      answered.should be <= 3 # 1 running + 2 waiting at most
      (busy + answered).should eq 6
    end
  end
end
