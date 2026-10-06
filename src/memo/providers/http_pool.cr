require "http/client"
require "openssl"

module Memo
  module Providers
    # Posts requests to an embedding API over reused connections, retrying
    # transient failures.
    #
    # HTTP::Client handles one request at a time, so idle clients are kept
    # in a small pool: concurrent requests each take one (opening a new
    # connection only when none is idle) and return it afterwards. A reused
    # connection skips the TCP and TLS handshakes.
    #
    # Retries rate limits (429, except an exhausted quota), server errors
    # (500, 502, 503, 504) and network errors, up to `max_retries` times.
    # Waits as the Retry-After header says, or backs off exponentially
    # (0.5 s, 1 s, 2 s, ... with jitter).
    class HTTPPool
      MAX_IDLE       = 8
      RETRY_STATUSES = {429, 500, 502, 503, 504}
      MAX_RETRY_WAIT = 20.seconds

      getter max_retries : Int32

      def initialize(base_url : String, @max_retries : Int32 = 3)
        @uri = URI.parse(base_url)
        @idle = [] of HTTP::Client
        @mutex = Mutex.new
      end

      # POST to `path` (e.g. "/v1/embeddings"). Returns the final response,
      # which may still be an error, or raises the last network error.
      def post(path : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
        attempt = 0
        loop do
          response = nil
          begin
            response = with_client { |client| client.post(path, headers: headers, body: body) }
          rescue ex : IO::Error | OpenSSL::SSL::Error
            raise ex if attempt >= @max_retries
          end

          if response
            return response if attempt >= @max_retries || !retryable?(response)
          end

          sleep retry_wait(attempt, response)
          attempt += 1
        end
      end

      # Close idle connections.
      def close : Nil
        @mutex.synchronize do
          @idle.each(&.close)
          @idle.clear
        end
      end

      private def retryable?(response : HTTP::Client::Response) : Bool
        return false unless RETRY_STATUSES.includes?(response.status_code)
        # OpenAI uses 429 for an exhausted quota too; waiting won't help
        !(response.status_code == 429 && response.body.includes?("insufficient_quota"))
      end

      private def retry_wait(attempt : Int32, response : HTTP::Client::Response?) : Time::Span
        if seconds = response.try(&.headers["Retry-After"]?).try(&.to_f?)
          return {seconds.seconds, MAX_RETRY_WAIT}.min
        end
        backoff = 0.5 * 2.0 ** attempt
        {(backoff * Random.rand(0.75..1.25)).seconds, MAX_RETRY_WAIT}.min
      end

      private def with_client(& : HTTP::Client -> HTTP::Client::Response) : HTTP::Client::Response
        client = @mutex.synchronize { @idle.pop? } || new_client
        begin
          response = yield client
        rescue ex
          client.close # don't reuse a connection in an unknown state
          raise ex
        end

        kept = @mutex.synchronize do
          next false if @idle.size >= MAX_IDLE
          @idle << client
          true
        end
        client.close unless kept
        response
      end

      private def new_client : HTTP::Client
        client = HTTP::Client.new(@uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 120.seconds
        client
      end
    end
  end
end
