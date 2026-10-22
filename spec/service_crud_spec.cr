require "./spec_helper"

describe Memo::Service do
  describe "Service CRUD" do
    describe "#create_service" do
      it "creates a new service configuration" do
        with_test_service do |service|
          info = service.create_service(
            name: "test-openai",
            format: "openai",
            model: "text-embedding-3-small",
            dimensions: 1536,
            max_tokens: 8191
          )

          info.name.should eq("test-openai")
          info.format.should eq("openai")
          info.model.should eq("text-embedding-3-small")
          info.dimensions.should eq(1536)
          info.max_tokens.should eq(8191)
          info.id.should be > 0
        end
      end

      it "creates a service with base_url" do
        with_test_service do |service|
          info = service.create_service(
            name: "azure",
            format: "openai",
            model: "ada-002",
            dimensions: 1536,
            max_tokens: 8191,
            base_url: "https://mycompany.openai.azure.com/"
          )

          info.base_url.should eq("https://mycompany.openai.azure.com/")
        end
      end
    end

    describe "#get_service" do
      it "retrieves a service by name" do
        with_test_service do |service|
          service.create_service(
            name: "lookup-test",
            format: "openai",
            model: "test-model",
            dimensions: 384,
            max_tokens: 512
          )

          found = service.get_service("lookup-test")
          found.should_not be_nil
          found.not_nil!.name.should eq("lookup-test")
          found.not_nil!.model.should eq("test-model")
        end
      end

      it "returns nil for unknown service" do
        with_test_service do |service|
          service.get_service("nonexistent").should be_nil
        end
      end
    end

    describe "#list_services" do
      it "lists all services including the initial mock service" do
        with_test_service do |service|
          services = service.list_services
          services.size.should be >= 1
          services.any? { |s| s.format == "mock" }.should be_true
        end
      end

      it "includes newly created services" do
        with_test_service do |service|
          service.create_service(
            name: "extra",
            format: "voyage",
            model: "voyage-3",
            dimensions: 1024,
            max_tokens: 32000
          )

          services = service.list_services
          services.any? { |s| s.name == "extra" }.should be_true
        end
      end
    end

    describe "#list_services_by_format" do
      it "filters services by format" do
        with_test_service do |service|
          service.create_service(
            name: "oai1",
            format: "openai",
            model: "model-a",
            dimensions: 384,
            max_tokens: 512
          )
          service.create_service(
            name: "voy1",
            format: "voyage",
            model: "voyage-3",
            dimensions: 1024,
            max_tokens: 32000
          )

          openai_services = service.list_services_by_format("openai")
          openai_services.all? { |s| s.format == "openai" }.should be_true

          voyage_services = service.list_services_by_format("voyage")
          voyage_services.all? { |s| s.format == "voyage" }.should be_true
        end
      end

      it "returns empty array for unknown format" do
        with_test_service do |service|
          service.list_services_by_format("unknown").should be_empty
        end
      end
    end

    describe "#update_service" do
      it "updates base_url" do
        with_test_service do |service|
          service.create_service(
            name: "updatable",
            format: "openai",
            model: "test",
            dimensions: 384,
            max_tokens: 512
          )

          updated = service.update_service("updatable", base_url: "https://new-url.com/v1")
          updated.should_not be_nil
          updated.not_nil!.base_url.should eq("https://new-url.com/v1")

          # Verify persisted
          fetched = service.get_service("updatable")
          fetched.not_nil!.base_url.should eq("https://new-url.com/v1")
        end
      end

      it "updates max_tokens" do
        with_test_service do |service|
          service.create_service(
            name: "updatable2",
            format: "openai",
            model: "test",
            dimensions: 384,
            max_tokens: 512
          )

          updated = service.update_service("updatable2", max_tokens: 2048)
          updated.should_not be_nil
          updated.not_nil!.max_tokens.should eq(2048)
        end
      end

      it "returns nil for unknown service" do
        with_test_service do |service|
          service.update_service("ghost", base_url: "http://nope").should be_nil
        end
      end
    end

    describe "#delete_service" do
      it "deletes a service with no embeddings" do
        with_test_service do |service|
          service.create_service(
            name: "deletable",
            format: "openai",
            model: "test",
            dimensions: 384,
            max_tokens: 512
          )

          result = service.delete_service("deletable")
          result.should be_true

          service.get_service("deletable").should be_nil
        end
      end

      it "returns false for unknown service" do
        with_test_service do |service|
          service.delete_service("ghost").should be_false
        end
      end
    end

    describe "#default_service and #set_default_service" do
      it "sets and gets the default service" do
        with_test_service do |service|
          service.create_service(
            name: "my-default",
            format: "openai",
            model: "test",
            dimensions: 384,
            max_tokens: 512
          )

          result = service.set_default_service("my-default")
          result.should be_true

          default = service.default_service
          default.should_not be_nil
          default.not_nil!.name.should eq("my-default")
        end
      end

      it "returns false for unknown service name" do
        with_test_service do |service|
          service.set_default_service("nonexistent").should be_false
        end
      end
    end

    describe "#service_stats" do
      it "returns stats for a service" do
        with_test_service do |service|
          stats = service.service_stats(service.service_name)
          stats.should_not be_nil
          stats.not_nil!.embeddings.should eq(0)
          stats.not_nil!.chunks.should eq(0)
        end
      end

      it "reflects indexed content" do
        with_test_service do |service|
          service.index(source_type: "event", source_id: 1_i64, text: "Test document")

          stats = service.service_stats(service.service_name)
          stats.should_not be_nil
          stats.not_nil!.embeddings.should be > 0
          stats.not_nil!.chunks.should be > 0
        end
      end

      it "returns nil for unknown service" do
        with_test_service do |service|
          service.service_stats("ghost").should be_nil
        end
      end
    end

    describe "#use_service" do
      it "switches to a different mock service" do
        with_test_service do |service|
          # Create a second mock service
          service.create_service(
            name: "mock2",
            format: "mock",
            model: "mock-model",
            dimensions: 8,
            max_tokens: 100
          )

          original_name = service.service_name
          service.use_service("mock2")
          service.service_name.should eq("mock2")
          service.service_name.should_not eq(original_name)
        end
      end

      it "raises for unknown service" do
        with_test_service do |service|
          expect_raises(ArgumentError, /not found/) do
            service.use_service("nonexistent")
          end
        end
      end

      it "caches queries under the new service" do
        with_test_db_path do |db_path|
          service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
          service.create_service(name: "mock2", format: "mock", model: "mock-model", dimensions: 8, max_tokens: 100)
          service.search("purple gorilla")

          service.use_service("mock2")
          service.search("purple gorilla")
          service.query_cache.hits.should eq 0 # the first service's vector isn't the new one's
          service.close

          # The query was saved for mock2
          reopened = Memo::Service.new(db_path: db_path, service: "mock2", chunking_max_tokens: 50)
          reopened.search("purple gorilla")
          reopened.query_cache.hits.should eq 1
          reopened.close
        end
      end

      it "checks the chunk size against the new service's limit" do
        with_test_service do |service|
          service.create_service(name: "small", format: "mock", model: "mock-small", dimensions: 8, max_tokens: 40)
          expect_raises(ArgumentError, /exceeds service limit/) do
            service.use_service("small")
          end
          service.service_name.should eq "mock"
        end
      end

      it "chunks with the new service's tokens per byte" do
        with_test_db_path do |db_path|
          service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
          info = service.create_service(name: "mock2", format: "mock", model: "mock-model", dimensions: 8, max_tokens: 100)
          Memo::Storage.update_tokens_per_byte(service.db, info.id, 1.0)
          ratio = service.get_service("mock2").not_nil!.tokens_per_byte
          ratio.should_not eq service.chunking_config.tokens_per_byte

          service.use_service("mock2")
          service.chunking_config.tokens_per_byte.should eq ratio
          service.close
        end
      end

      it "stays on the current service when the new one's index is in use" do
        with_test_db_path do |db_path|
          service = Memo::Service.new(db_path: db_path, service: "mock", chunking_max_tokens: 50)
          service.create_service(name: "mock2", format: "mock", model: "mock-model", dimensions: 8, max_tokens: 100)
          holder = Memo::Service.new(db_path: db_path, service: "mock2", chunking_max_tokens: 50)

          expect_raises(Memo::USearchIndex::InUse) { service.use_service("mock2") }
          service.service_name.should eq "mock"
          service.index(source_type: "doc", source_id: 1_i64, text: "still writable")
          service.search("still writable").first.source_id.should eq 1
          holder.close
          service.close
        end
      end
    end
  end
end
