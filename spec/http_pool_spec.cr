require "./spec_helper"
require "http/server"

# A local stand-in for the OpenAI embeddings endpoint. Each request gets the
# next scripted {status, body} (a normal embedding response once the script
# runs out), and the server records which connection (client port) it came on.
private class FakeEmbeddingAPI
  getter requests = 0
  getter ports = Set(Int32).new
  getter bodies = [] of JSON::Any
  getter base_url : String

  def initialize(@script = [] of {Int32, String}, @delay : Time::Span = Time::Span.zero)
    @server = HTTP::Server.new do |ctx|
      @requests += 1
      ctx.request.remote_address.as?(Socket::IPAddress).try { |address| @ports << address.port }
      sleep @delay unless @delay.zero?

      body = ctx.request.body.try(&.gets_to_end) || ""
      @bodies << JSON.parse(body) unless body.empty?
      status, response = @script.shift? || {200, embeddings_for(body)}
      ctx.response.status_code = status
      ctx.response.headers["Retry-After"] = "0" unless status == 200
      ctx.response.content_type = "application/json"
      ctx.response.print response
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @base_url = "http://127.0.0.1:#{address.port}/v1"
    spawn { @server.listen }
  end

  def close
    @server.close
  end

  private def embeddings_for(request_body : String) : String
    inputs = JSON.parse(request_body)["input"].as_a
    {
      data:  inputs.map_with_index { |_, i| {index: i, embedding: [0.25, 0.5]} },
      usage: {total_tokens: inputs.size},
    }.to_json
  end
end

private def with_fake_api(script = [] of {Int32, String}, delay = Time::Span.zero, &)
  api = FakeEmbeddingAPI.new(script, delay)
  provider = Memo::Providers::OpenAI.new(api_key: "test", model: "test", base_url: api.base_url)
  yield api, provider
ensure
  api.try(&.close)
end

RATE_LIMITED = {429, %({"error": {"message": "Rate limit reached", "code": "rate_limit_exceeded"}})}

describe Memo::Providers::HTTPPool do
  it "retries rate limits and server errors" do
    with_fake_api([RATE_LIMITED, {503, "{}"}]) do |api, provider|
      provider.embed_text("hello")[0].should eq [0.25, 0.5]
      api.requests.should eq 3
    end
  end

  it "returns the error after max_retries" do
    with_fake_api(Array.new(5) { {500, %({"error": {"message": "boom"}})} }) do |api, provider|
      expect_raises(Exception, "OpenAI API error (500): boom") { provider.embed_text("hello") }
      api.requests.should eq 4 # first try + 3 retries
    end
  end

  it "doesn't retry an exhausted quota" do
    quota = {429, %({"error": {"message": "You exceeded your current quota", "code": "insufficient_quota"}})}
    with_fake_api([quota]) do |api, provider|
      expect_raises(Exception, "exceeded your current quota") { provider.embed_text("hello") }
      api.requests.should eq 1
    end
  end

  it "retries network errors, then raises the last one" do
    # A port nothing listens on: bind one, then close it
    server = HTTP::Server.new { }
    port = server.bind_tcp("127.0.0.1", 0).port
    server.close

    pool = Memo::Providers::HTTPPool.new("http://127.0.0.1:#{port}", max_retries: 1)
    started = Time.instant
    expect_raises(Socket::ConnectError) do
      pool.post("/v1/embeddings", HTTP::Headers.new, "{}")
    end
    (Time.instant - started).should be >= 375.milliseconds # one backoff (0.5 s, -25% jitter)
  end

  it "reuses a connection for sequential requests" do
    with_fake_api do |api, provider|
      5.times { |i| provider.embed_text("text #{i}") }
      api.requests.should eq 5
      api.ports.size.should eq 1
    end
  end

  it "opens a connection per concurrent request and reuses them" do
    with_fake_api(delay: 50.milliseconds) do |api, provider|
      2.times do
        done = Channel(Nil).new
        4.times { |i| spawn { provider.embed_text("text #{i}"); done.send(nil) } }
        4.times { done.receive }
      end
      api.requests.should eq 8
      api.ports.size.should eq 4
    end
  end
end

describe Memo::Providers::OpenAI do
  it "passes input_type through for OpenAI-compatible APIs that use it" do
    with_fake_api do |api, provider|
      provider.embed_text("hello", "query")
      api.bodies.first["input_type"].should eq "query"
      api.bodies.first.as_h.keys.sort.should eq ["encoding_format", "input", "input_type", "model"]
    end
  end

  it "asks text-embedding-3 models for the service's dimensions" do
    with_fake_api do |api, _|
      large = Memo::Providers::OpenAI.new(api_key: "test", model: "text-embedding-3-large", base_url: api.base_url, dimensions: 1024)
      large.embed_text("hello")
      api.bodies.last["dimensions"].as_i.should eq 1024

      ada = Memo::Providers::OpenAI.new(api_key: "test", model: "text-embedding-ada-002", base_url: api.base_url, dimensions: 1536)
      ada.embed_text("hello")
      api.bodies.last["dimensions"]?.should be_nil # ada-002 rejects it
    end
  end
end
