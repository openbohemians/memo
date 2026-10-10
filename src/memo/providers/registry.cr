module Memo
  module Providers
    # Provider factory
    #
    # Creates provider instances from format names.
    # Formats represent API protocols (e.g., "openai" format works with
    # OpenAI, Azure OpenAI, and any OpenAI-compatible API).
    #
    # ## Usage
    #
    # ```
    # provider = Memo::Providers::Registry.create(
    #   format: "openai",
    #   api_key: "sk-...",
    #   model: "text-embedding-3-small",
    #   base_url: "https://custom.api.com/v1" # optional
    # )
    # ```
    module Registry
      # Create a provider instance
      #
      # Returns nil if format is not supported.
      def self.create(
        format : String,
        api_key : String? = nil,
        model : String = "",
        base_url : String? = nil,
        dimensions : Int32? = nil,
      ) : Providers::Base?
        case format
        when "openai"
          raise ArgumentError.new("api_key required for openai format") unless api_key
          final_base_url = base_url || Providers::OpenAI::DEFAULT_BASE_URL
          Providers::OpenAI.new(api_key, model, final_base_url, dimensions)
        when "voyage"
          raise ArgumentError.new("api_key required for voyage format") unless api_key
          final_base_url = base_url || Providers::Voyage::DEFAULT_BASE_URL
          Providers::Voyage.new(api_key, model, final_base_url)
        when "arcana", "arcana/openai"
          raise ArgumentError.new("api_key required for arcana format") unless api_key
          final_base_url = base_url || "https://api.openai.com/v1/embeddings"
          arcana_provider = ::Arcana::AI::Embed::OpenAI.new(
            api_key: api_key,
            model: model,
            endpoint: final_base_url
          )
          Providers::Arcana.new(arcana_provider, model: model,
            dimensions: Providers::OpenAI.shortenable?(model) ? dimensions : nil)
        when "arcana/voyage"
          raise ArgumentError.new("api_key required for arcana/voyage format") unless api_key
          final_base_url = base_url || "https://api.voyageai.com/v1/embeddings"
          arcana_provider = ::Arcana::AI::Embed::Voyage.new(
            api_key: api_key,
            model: model,
            endpoint: final_base_url
          )
          Providers::Arcana.new(arcana_provider, model: model)
        when "bus/openai"
          Providers::Bus.new(target: "openai:embed", model: model)
        when "bus/voyage"
          Providers::Bus.new(target: "voyage:embed", model: model)
        when "mock"
          Providers::Mock.new
        else
          nil
        end
      end
    end
  end
end
