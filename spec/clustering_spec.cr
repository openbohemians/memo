require "./spec_helper"

describe Memo::Clustering do
  it "groups consecutive sources with similar embeddings" do
    with_test_service do |service|
      (1_i64..3_i64).each { |i| service.index(source_type: "event", source_id: i, text: "the dragon attacks the village") }
      (4_i64..6_i64).each { |i| service.index(source_type: "event", source_id: i, text: "a quiet morning at the market") }

      clusters = Memo::Clustering.sequential(db: service.db, service_id: service.service_id,
        usearch_index: service.usearch_index, source_type: "event", external_ids: (1_i64..6_i64).to_a,
        threshold: 0.99, min_cluster_size: 3)
      clusters.map(&.source_ids).should eq [[1_i64, 2_i64, 3_i64], [4_i64, 5_i64, 6_i64]]
    end
  end
end
