require "./spec_helper"

# Answers every embed request with one fixed vector per text, reporting
# `usage` as given (nil: the provider reported no count)
private class FakeEmbedder < Arcana::AI::Embed::Provider
  def initialize(@usage : Arcana::AI::Usage?)
  end

  def name : String
    "fake"
  end

  def embed(request : Arcana::AI::Embed::Request) : Arcana::AI::Embed::Result
    Arcana::AI::Embed::Result.new(
      embeddings: request.texts.map { [0.25, 0.5] },
      token_counts: request.texts.map { 2 },
      usage: @usage,
    )
  end
end

private def embed_reply(fields : Hash(String, JSON::Any)) : JSON::Any
  vectors = JSON::Any.new([JSON::Any.new([JSON::Any.new(0.25)]), JSON::Any.new([JSON::Any.new(0.5)])])
  JSON::Any.new({"embeddings" => vectors}.merge(fields))
end

describe Memo::Providers::Arcana do
  it "counts tokens from usage" do
    usage = Arcana::AI::Usage.new(input: 7_i64)
    provider = Memo::Providers::Arcana.new(FakeEmbedder.new(usage))
    provider.embed_texts(["purple", "gorilla"]).total_tokens.should eq 7
  end

  it "counts no tokens when the provider reported none" do
    provider = Memo::Providers::Arcana.new(FakeEmbedder.new(nil))
    provider.embed_texts(["purple", "gorilla"]).total_tokens.should eq 0
  end
end

describe Memo::Providers::Bus do
  it "counts tokens from the reply's usage, split across the texts" do
    usage = JSON::Any.new({"input" => JSON::Any.new(10_i64), "output" => JSON::Any.new(0_i64)})
    result = Memo::Providers::Bus.parse_reply(embed_reply({"usage" => usage, "cost" => JSON::Any.new(0.0001)}), 2)
    result.embeddings.should eq [[0.25], [0.5]]
    result.total_tokens.should eq 10
    result.token_counts.should eq [5, 5]
  end

  it "no longer reads the deprecated total_tokens" do
    result = Memo::Providers::Bus.parse_reply(embed_reply({"total_tokens" => JSON::Any.new(9_i64)}), 2)
    result.total_tokens.should eq 0
    result.token_counts.should eq [0, 0]
  end
end
