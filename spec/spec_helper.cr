require "spec"
require "../src/memo"
require "file_utils"

# Delete a test database and every file beside it named after it: SQLite's
# -wal/-shm/-journal, and memo's index with its checkpoint and lock. Only
# this test's files: other programs may keep index files in the same
# temp directory.
def delete_test_files(db_path : String)
  stem = File.basename(db_path, File.extname(db_path))
  Dir.glob(File.join(File.dirname(db_path), "#{stem}*")).each { |f| File.delete(f) rescue nil }
end

# PostgreSQL server for the Postgres specs (MEMO_TEST_PG), as a URL without a
# database name, e.g. postgres://postgres:postgres@localhost:5432. Without
# it, those specs are pending.
PG_TEST_SERVER = ENV["MEMO_TEST_PG"]?.try(&.rstrip('/'))

# Yields the URL of a fresh, empty PostgreSQL database and a directory for
# its index files; drops both afterwards.
def with_pg_database(&)
  server = PG_TEST_SERVER
  pending!("set MEMO_TEST_PG to run the Postgres specs") unless server
  name = "memo_test_#{Random::Secure.hex(6)}"
  index_dir = File.tempname("memo_pg_index")
  Dir.mkdir_p(index_dir)
  admin = DB.open("#{server}/postgres")
  admin.exec("CREATE DATABASE #{name}")
  begin
    yield "#{server}/#{name}", index_dir
  ensure
    admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
    admin.close
    FileUtils.rm_rf(index_dir)
  end
end

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
    delete_test_files(temp_file)
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
    delete_test_files(db_path)
  end
end

# Helper to create a test service instance
def with_test_service(&block : Memo::Service ->)
  with_test_db_path do |db_path|
    service = Memo::Service.new(
      db_path: db_path,
      service: "mock",
      chunking_max_tokens: 50 # Mock provider has max_tokens of 100
    )

    begin
      yield service
    ensure
      service.close
    end
  end
end
