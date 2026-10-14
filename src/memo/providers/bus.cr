require "arcana-core"

module Memo
  module Providers
    # Bus-based embedding provider.
    #
    # Routes embedding requests through the Arcana bus to a remote
    # embedding service (e.g. `openai:embed`, `voyage:embed`).
    #
    # Requires an Arcana::Client to be available — typically set once
    # at process startup via `Memo::Providers::Bus.client = ...`.
    #
    # Bus replies don't include per-text token counts, only `usage` for the
    # whole call (arcana 0.35 and later; absent when the provider reported
    # none). We distribute its input count evenly across texts (same
    # approach as Memo::Providers::OpenAI when the API doesn't itemize).
    class Bus
      include Base

      # Process-wide Arcana::Client used by all Bus providers.
      # Set once at process startup (e.g. in bin/memo-arcana.cr).
      class_property client : ::Arcana::Client?

      DEFAULT_TIMEOUT = 60.seconds

      getter target : String      # bus address, e.g. "openai:embed"
      getter model : String
      getter from_address : String

      def initialize(
        @target : String,
        @model : String = "",
        @from_address : String = "memo:rag",
        @timeout : Time::Span = DEFAULT_TIMEOUT
      )
      end

      def embed_text(text : String, input_type : String? = nil) : {Array(Float64), Int32}
        result = embed_texts([text], input_type)
        {result.embeddings.first, result.token_counts.first}
      end

      def embed_texts(texts : Array(String), input_type : String? = nil) : EmbedResult
        return EmbedResult.new([] of Array(Float64), [] of Int32, 0) if texts.empty?

        client = self.class.client
        raise "Memo::Providers::Bus requires an Arcana::Client (set Memo::Providers::Bus.client)" unless client

        # Build payload for the embed service
        payload = JSON::Any.new({
          "texts" => JSON::Any.new(texts.map { |t| JSON::Any.new(t) }),
          "model" => JSON::Any.new(@model),
        } of String => JSON::Any)

        # Wrap in protocol envelope
        request_payload = ::Arcana::Protocol.request(payload)

        envelope = ::Arcana::Envelope.new(
          from: @from_address,
          to: @target,
          subject: "embed",
          payload: request_payload,
          correlation_id: Random::Secure.hex(8),
        )

        reply = client.request(envelope, timeout: @timeout)
        raise "Bus request to #{@target} timed out after #{@timeout.total_seconds}s" unless reply

        # Unwrap protocol layer
        if ::Arcana::Protocol.error?(reply.payload)
          msg = ::Arcana::Protocol.message(reply.payload) || "unknown error"
          raise "Bus embed via #{@target} failed: #{msg}"
        end

        data = ::Arcana::Protocol.data(reply.payload) || raise "Bus embed: empty reply"
        self.class.parse_reply(data, texts.size)
      end

      # An embed service's reply data as an EmbedResult. The token count
      # comes from `usage.input`; without `usage` it is 0, as when the
      # provider reports none.
      def self.parse_reply(data : JSON::Any, count : Int32) : EmbedResult
        embeddings_json = data["embeddings"]?.try(&.as_a?) || raise "Bus embed: no embeddings in reply"
        embeddings = embeddings_json.map do |arr|
          arr.as_a.map(&.as_f)
        end

        total_tokens = data["usage"]?.try(&.["input"]?).try(&.as_i64?).try(&.to_i32) || 0
        avg_tokens = count > 0 ? (total_tokens.to_f / count).round.to_i : 0
        token_counts = Array.new(count, avg_tokens)

        EmbedResult.new(embeddings, token_counts, total_tokens)
      end
    end
  end
end
