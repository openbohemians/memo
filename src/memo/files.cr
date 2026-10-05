require "ignore"
require "magic"
require "digest/sha256"

module Memo
  # File indexing support for memo CLI
  #
  # Provides directory walking with ignore file support, binary file detection,
  # and file metadata tracking for incremental updates.
  module Files
    extend self

    # File info for indexing
    struct FileInfo
      getter path : String        # Relative path
      getter content_hash : Bytes # SHA256 of content
      getter mtime : Int64        # Modification time (Unix ms)
      getter size : Int64         # File size in bytes

      def initialize(@path, @content_hash, @mtime, @size)
      end
    end

    # Stored file record from database
    struct FileRecord
      getter source_id : Int64
      getter path : String
      getter content_hash : Bytes
      getter mtime : Int64
      getter size : Int64

      def initialize(@source_id, @path, @content_hash, @mtime, @size)
      end
    end

    # Walk directory and yield text files, respecting ignore patterns
    #
    # Uses ignoreme for .gitignore-style filtering.
    # Uses magic.cr to detect and skip binary files.
    #
    # Options:
    # - root: Directory to walk
    # - ignore_file: Ignore file name (default ".gitignore")
    def walk(
      root : String,
      ignore_file : String = ".gitignore",
      &block : String ->
    )
      root_path = Path.new(root).expand

      # Build ignore matcher from root
      ignore_path = root_path / ignore_file
      matcher = if File.exists?(ignore_path)
                  Ignore.parse(File.read(ignore_path))
                else
                  Ignore::Matcher.new
                end

      walk_recursive(root_path, root_path, matcher, &block)
    end

    # Collect all text files in directory
    def collect(root : String, ignore_file : String = ".gitignore") : Array(String)
      files = [] of String
      walk(root, ignore_file) { |path| files << path }
      files
    end

    # Check if file is binary using libmagic
    def binary?(path : String) : Bool
      info = Magic.detect(path)
      mime = info.mime_type

      # Text types start with "text/" or are specific text formats
      !mime.starts_with?("text/") &&
        !mime.includes?("json") &&
        !mime.includes?("xml") &&
        !mime.includes?("javascript") &&
        !mime.includes?("script")
    rescue
      # If magic fails, fall back to null byte detection
      binary_by_content?(path)
    end

    # Fallback binary detection by checking for null bytes
    def binary_by_content?(path : String, sample_size : Int32 = 8192) : Bool
      File.open(path, "rb") do |file|
        buffer = Bytes.new(sample_size)
        bytes_read = file.read(buffer)
        buffer[0, bytes_read].includes?(0_u8)
      end
    rescue
      true # Assume binary if can't read
    end

    # Compute SHA256 hash of file content
    def content_hash(path : String) : Bytes
      digest = Digest::SHA256.new
      File.open(path, "rb") do |file|
        buffer = Bytes.new(8192)
        while (bytes_read = file.read(buffer)) > 0
          digest.update(buffer[0, bytes_read])
        end
      end
      digest.final
    end

    # Get file info (path, hash, mtime, size)
    def file_info(path : String, root : String) : FileInfo
      stat = File.info(path)
      relative_path = Path.new(path).relative_to(root).to_s
      hash = content_hash(path)
      mtime = stat.modification_time.to_unix_ms
      size = stat.size

      FileInfo.new(relative_path, hash, mtime, size)
    end

    # Store file record in database
    def store(db : DB::Database, source_id : Int64, info : FileInfo)
      db.memo_queries.upsert_file(source_id, info.path, info.content_hash, info.mtime, info.size, Time.utc.to_unix_ms)
    end

    # Get file record by path
    def get_by_path(db : DB::Database, path : String) : FileRecord?
      db.memo_queries.get_file_by_path(path)
    end

    # Get file record by content hash
    def get_by_hash(db : DB::Database, hash : Bytes) : FileRecord?
      db.memo_queries.get_file_by_hash(hash)
    end

    # Get file record by source_id
    def get_by_source(db : DB::Database, source_id : Int64) : FileRecord?
      db.memo_queries.get_file_by_source(source_id)
    end

    # Delete file record
    def delete(db : DB::Database, source_id : Int64) : Bool
      db.memo_queries.delete_file(source_id) > 0
    end

    # Check if file needs re-indexing (mtime changed)
    def needs_update?(record : FileRecord, current_mtime : Int64) : Bool
      record.mtime != current_mtime
    end

    # List all indexed files
    def list(db : DB::Database, limit : Int32 = 100, offset : Int32 = 0) : Array(FileRecord)
      db.memo_queries.list_files(limit, offset)
    end

    # Count indexed files
    def count(db : DB::Database) : Int64
      db.memo_queries.count_files
    end

    private def walk_recursive(
      current : Path,
      root : Path,
      matcher : Ignore::Matcher,
      &block : String ->
    )
      Dir.each_child(current.to_s) do |entry|
        # Always skip .git directory
        next if entry == ".git"

        full_path = current / entry
        relative_path = full_path.relative_to(root).to_s

        # Check if ignored
        next if matcher.ignores?(relative_path)
        if File.directory?(full_path.to_s)
          # Recurse into directory (add trailing slash for directory matching)
          next if matcher.ignores?(relative_path + "/")
          walk_recursive(full_path, root, matcher, &block)
        else
          # Skip binary files
          next if binary?(full_path.to_s)
          yield full_path.to_s
        end
      end
    end
  end
end
