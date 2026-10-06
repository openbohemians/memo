require "spec"
require "../src/memo"

# Helper to create a test database connection (for low-level API tests)
def with_test_db(&block : DB::Database ->)
  # Use file-based temp database to avoid connection pool isolation issues
  # In-memory databases are per-connection, so transactions can't see schema
  temp_file = File.tempname("memo_test", ".db")
  db = DB.open("sqlite3:#{temp_file}")
  Memo::Database.load_schema(db)

  begin
    yield db
  ensure
    db.close
    File.delete(temp_file) if File.exists?(temp_file)
    # Clean up USearch index files
    Dir.glob("#{File.dirname(temp_file)}/*.usearch").each { |f| File.delete(f) rescue nil }
  end
end

# Helper to create a source record for low-level tests
# Returns the internal source ID
def create_test_source(db : DB::Database, source_type : String, external_id : Int64) : Int64
  db.exec(
    "INSERT INTO memo_sources (source_type, external_int, created_at) VALUES (?, ?, ?)",
    source_type, external_id, Time.utc.to_unix_ms
  )
  db.scalar("SELECT last_insert_rowid()").as(Int64)
end

# Helper to create a test database path
def with_test_db_path(&block : String ->)
  # Create temp file path for test database
  db_path = File.tempname("memo_test", ".db")

  begin
    yield db_path
  ensure
    File.delete(db_path) if File.exists?(db_path)
    # Clean up USearch index files and their journal checkpoints
    Dir.glob("#{File.dirname(db_path)}/*.usearch").each { |f| File.delete(f) rescue nil }
    Dir.glob("#{File.dirname(db_path)}/*.usearch.checkpoint").each { |f| File.delete(f) rescue nil }
  end
end

# Helper to create a test service instance
def with_test_service(&block : Memo::Service ->)
  with_test_db_path do |db_path|
    service = Memo::Service.new(
      db_path: db_path,
      service: "mock",
      chunking_max_tokens: 50  # Mock provider has max_tokens of 100
    )

    begin
      yield service
    ensure
      service.close
    end
  end
end
