require "arcana-ai"

module Memo
  module Providers
    # Arcana embedding provider
    #
    # Wraps an arcana-ai embedder (Arcana::AI::Embed::Provider) to implement
    # the Memo provider interface.
    # Supports any provider Arcana supports (OpenAI, Voyage AI, etc.)
    # with built-in batching and retry.
    class Arcana
      include Base

      getter provider : ::Arcana::AI::Embed::Provider
      getter model : String
      getter dimensions : Int32?
      getter batch_size : Int32
      getter max_retries : Int32

      def initialize(
        @provider : ::Arcana::AI::Embed::Provider,
        @model : String = "",
        @dimensions : Int32? = nil,
        @batch_size : Int32 = 100,
        @max_retries : Int32 = 3
      )
      end

      def embed_text(text : String, input_type : String? = nil) : {Array(Float64), Int32}
        result = embed_texts([text], input_type)
        {result.embeddings.first, result.token_counts.first}
      end

      def embed_texts(texts : Array(String), input_type : String? = nil) : EmbedResult
        return EmbedResult.new([] of Array(Float64), [] of Int32, 0) if texts.empty?

        request = ::Arcana::AI::Embed::Request.new(
          texts: texts,
          dimensions: @dimensions,
          input_type: input_type,
        )

        response = @provider.batch_embed_with_retry(
          request,
          batch_size: @batch_size,
          max_retries: @max_retries
        )

        EmbedResult.new(response.embeddings, response.token_counts, response.total_tokens)
      end
    end
  end
end
