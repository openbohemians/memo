require "./spec_helper"

describe Memo::USearchIndex do
  it "grows past the initial 1,024-vector reservation" do
    index = USearch::Index.new(dimensions: 8, metric: :cos, quantization: :f16)
    1_100.times do |i|
      vector = Array.new(8) { |j| ((i + j) % 13).to_f64 / 13.0 }
      Memo::USearchIndex.add(index, (i + 1).to_u64, vector)
    end
    index.size.should eq 1_100
    index.capacity.should be >= 1_100
  ensure
    index.try(&.close)
  end
end
