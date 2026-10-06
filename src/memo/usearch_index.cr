require "usearch"

module Memo
  # USearch HNSW index management for fast approximate nearest neighbor search.
  #
  # Wraps USearch index lifecycle: file naming, open/save/close, type conversion,
  # and vector operations. All Float64↔Float32 conversion happens here.
  #
  # One index per service (isolated vector spaces). Index files are named
  # by service format, model, and dimensions:
  #   memo.openai--text-embedding-3-small--1536.usearch
  module USearchIndex
    extend self

    # Default directory for index files when no db_path is available
    # (e.g., PostgreSQL backend). Follows XDG Base Directory spec,
    # with fallback to /var/lib/memo/indices for system users.
    DEFAULT_INDEX_DIR = begin
      if xdg = ENV["XDG_DATA_HOME"]?
        File.join(xdg, "memo", "indices")
      else
        home = Path.home.to_s
        if home == "/nonexistent" || home.empty? || !Dir.exists?(home)
          "/var/lib/memo/indices"
        else
          File.join(home, ".local", "share", "memo", "indices")
        end
      end
    end

    # Build the index file path from a database path.
    #
    # Path: {db_dir}/{db_stem}.{format}--{model}--{dimensions}.usearch
    # Path-unsafe characters in format/model are replaced with hyphens.
    def index_path(db_path : String, format : String, model : String, dimensions : Int32) : String
      dir = File.dirname(db_path)
      stem = File.basename(db_path, File.extname(db_path))
      index_path_in_dir(dir, format, model, dimensions, stem)
    end

    # Build the index file path from an explicit directory.
    #
    # Path: {dir}/{stem}.{format}--{model}--{dimensions}.usearch
    # If no stem is provided, uses "memo" as default.
    def index_path_in_dir(dir : String, format : String, model : String, dimensions : Int32, stem : String = "memo") : String
      safe_format = format.gsub(/[^a-zA-Z0-9\-\.]/, "-")
      safe_model = model.gsub(/[^a-zA-Z0-9\-\.]/, "-")
      File.join(dir, "#{stem}.#{safe_format}--#{safe_model}--#{dimensions}.usearch")
    end

    # Open or create a USearch index at a specific path.
    #
    # If the index file exists on disk, loads it. Otherwise creates a new
    # empty index with cosine metric and f16 quantization.
    def open(path : String, dimensions : Int32) : USearch::Index
      if File.exists?(path)
        USearch::Index.load(path, dimensions: dimensions, metric: :cos, quantization: :f16)
      else
        Dir.mkdir_p(File.dirname(path))
        USearch::Index.new(dimensions: dimensions, metric: :cos, quantization: :f16)
      end
    end

    # Load the index at `path`, or create an empty one when the file is
    # missing or can't be loaded (corrupt, wrong dimensions). Returns the
    # index and whether it was loaded from the file.
    def load_or_create(path : String, dimensions : Int32) : {USearch::Index, Bool}
      if File.exists?(path)
        begin
          return {USearch::Index.load(path, dimensions: dimensions, metric: :cos, quantization: :f16), true}
        rescue
          # Fall through: the caller rebuilds it from stored vectors
        end
      end
      Dir.mkdir_p(File.dirname(path))
      {USearch::Index.new(dimensions: dimensions, metric: :cos, quantization: :f16), false}
    end

    # Save the index to disk.
    #
    # Writes a temporary file and renames it over `path`, so a crash
    # mid-save leaves the previous file intact.
    def save(index : USearch::Index, path : String)
      Dir.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      index.save(tmp)
      File.rename(tmp, path)
    end

    # Path of the journal checkpoint saved beside an index file.
    def checkpoint_path(path : String) : String
      "#{path}.checkpoint"
    end

    # Save and close the index, freeing resources.
    def close(index : USearch::Index, path : String)
      save(index, path) rescue nil
      index.close
    end

    # Delete the index file (and its journal checkpoint) from disk.
    def delete_file(path : String)
      File.delete(path) if File.exists?(path)
      File.delete(checkpoint_path(path)) if File.exists?(checkpoint_path(path))
    end

    # Convert Float64 array to Float32 array for USearch.
    def to_f32(embedding : Array(Float64)) : Array(Float32)
      embedding.map(&.to_f32)
    end

    # Add a vector to the index.
    #
    # Key is the embedding rowid (SQLite rowid or PostgreSQL eid).
    # Embedding is converted from Float64 to Float32 at this boundary.
    def add(index : USearch::Index, key : UInt64, embedding : Array(Float64))
      # A new embedding row can reuse a deleted row's rowid (SQLite), while a
      # saved index file may still hold the deleted vector. The database row
      # is authoritative, so replace whatever the index has under this key.
      index.remove(key) if index.contains?(key)

      # The Crystal USearch wrapper reserves 1,024 slots on first add. Grow
      # explicitly before that reservation fills so large indexes keep working.
      capacity = index.capacity
      if index.size >= capacity
        index.reserve(Math.max(capacity.to_i * 2, 1024))
      end
      index.add(key, to_f32(embedding))
    end

    # Remove a vector from the index by key.
    def remove(index : USearch::Index, key : UInt64)
      index.remove(key) if index.contains?(key)
    end

    # Index changes made during a database transaction, applied in order
    # once it commits. The index can't roll back, so changing it earlier
    # would leave it out of step with the database after a rollback.
    class Pending
      @changes = [] of {UInt64, Array(Float64)?} # nil embedding = remove

      def add(key : UInt64, embedding : Array(Float64))
        @changes << {key, embedding}
      end

      def remove(key : UInt64)
        @changes << {key, nil}
      end

      def apply(index : USearch::Index)
        @changes.each do |key, embedding|
          if embedding
            USearchIndex.add(index, key, embedding)
          else
            USearchIndex.remove(index, key)
          end
        end
        @changes.clear
      end
    end

    # Search for k nearest neighbors (unfiltered).
    #
    # Returns USearch::SearchResult array with keys and distances.
    # Cosine distance = 1 - similarity, so similarity = 1 - distance.
    def search(index : USearch::Index, query : Array(Float64), k : Int32) : Array(USearch::SearchResult)
      index.search(to_f32(query), k: k)
    end

    # Search with a filter predicate on keys.
    #
    # Only results where the filter block returns true are included.
    # Use this with a Set of valid rowids from SQL pre-filtering.
    def filtered_search(index : USearch::Index, query : Array(Float64), k : Int32, &filter : UInt64 -> Bool) : Array(USearch::SearchResult)
      index.filtered_search(to_f32(query), k: k, &filter)
    end

    # Retrieve a vector from the index by key.
    #
    # Returns Float64 array for compatibility with the rest of Memo,
    # or nil if the key doesn't exist.
    def get_vector(index : USearch::Index, key : UInt64) : Array(Float64)?
      vec_f32 = index.get(key)
      return nil unless vec_f32
      vec_f32.map(&.to_f64)
    end
  end
end
