require "http/client"
require "json"

module Memo
  module Providers
    # OpenAI embedding provider
    #
    # Generates embeddings using OpenAI's embeddings API.
    # Compatible with OpenAI, Azure OpenAI, and other OpenAI-compatible APIs.
    class OpenAI
      include Base

      DEFAULT_BASE_URL = "https://api.openai.com/v1"

      getter api_key : String
      getter model : String
      getter base_url : String

      def initialize(
        @api_key : String,
        @model : String = "text-embedding-3-small",
        @base_url : String = DEFAULT_BASE_URL
      )
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
        body["encoding_format"] = "float"
        body["input_type"] = input_type if input_type

        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds

        # Close the connection once the body is read; each call opens its
        # own, so under load they'd otherwise pile up until GC.
        response = begin
          client.post(
            uri.request_target,
            headers: HTTP::Headers{
              "Authorization" => "Bearer #{@api_key}",
              "Content-Type"  => "application/json",
            },
            body: body.to_json
          )
        ensure
          client.close
        end

        unless response.success?
          error_msg = begin
            error_data = JSON.parse(response.body)
            if msg = error_data["error"]?.try(&.["message"]?.try(&.as_s?))
              msg
            else
              response.body
            end
          rescue
            response.body
          end
          raise Exception.new("OpenAI API error (#{response.status_code}): #{error_msg}")
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
