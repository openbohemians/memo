require "http/client"
require "json"
require "./http_pool"

module Memo
  module Providers
    # Voyage AI embedding provider
    #
    # Generates embeddings using Voyage AI's embeddings API.
    # Supports voyage-3, voyage-3-lite, voyage-code-3, and domain-specific models.
    class Voyage
      include Base

      DEFAULT_BASE_URL = "https://api.voyageai.com/v1"

      getter api_key : String
      getter model : String
      getter base_url : String

      def initialize(
        @api_key : String,
        @model : String = "voyage-3",
        @base_url : String = DEFAULT_BASE_URL
      )
        @http = HTTPPool.new(@base_url)
      end

      def embed_text(text : String, input_type : String? = nil) : {Array(Float64), Int32}
        result = embed_texts([text], input_type)
        {result.embeddings.first, result.token_counts.first}
      end

      def embed_texts(texts : Array(String), input_type : String? = nil) : EmbedResult
        return EmbedResult.new([] of Array(Float64), [] of Int32, 0) if texts.empty?

        uri = URI.parse("#{@base_url}/embeddings")
        body = Hash(String, String | Array(String)).new
        body["model"] = @model
        body["input"] = texts
        body["input_type"] = input_type if input_type

        # Reuses connections and retries rate limits and transient errors
        response = @http.post(
          uri.request_target,
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{@api_key}",
            "Content-Type"  => "application/json",
          },
          body: body.to_json
        )

        unless response.success?
          error_msg = begin
            error_data = JSON.parse(response.body)
            if msg = error_data["error"]?.try(&.["message"]?.try(&.as_s?))
              msg
            elsif msg = error_data["detail"]?.try(&.as_s?)
              msg
            else
              response.body
            end
          rescue
            response.body
          end
          raise Exception.new("Voyage AI API error (#{response.status_code}): #{error_msg}")
        end

        data = JSON.parse(response.body)

        # Sort by index to ensure correct order (API may return out of order)
        sorted_data = data["data"].as_a.sort_by { |item| item["index"].as_i }
        embeddings = sorted_data.map do |item|
          item["embedding"].as_a.map(&.as_f)
        end

        total_tokens = data["usage"]["total_tokens"].as_i
        avg_tokens = (total_tokens.to_f / texts.size).round.to_i
        token_counts = Array.new(texts.size, avg_tokens)

        EmbedResult.new(embeddings, token_counts, total_tokens)
      end
    end
  end
end
