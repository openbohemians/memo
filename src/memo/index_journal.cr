module Memo
  # Keeps a service's USearch index recoverable from the database.
  #
  # Every vector memo stores goes into memo_vectors, and every embedding
  # added or removed is logged in memo_index_log, in the same transaction as
  # the change. Saving the index records a checkpoint beside the file (the
  # last log entry it includes) and prunes the log up to it.
  #
  # Opening the index replays only the entries after the checkpoint, so a
  # clean restart does no work. When the file is missing, corrupt, or older
  # than the pruned log, the index is rebuilt from memo_vectors. Neither path
  # calls the embedding API.
  #
  # Replay is idempotent: each logged embedding is set to its current state
  # in the database (added if it has a stored vector, removed otherwise).
  # A checkpoint that lags the file only costs extra replay.
  #
  # The checkpoint also records the database's id and the service's, so a
  # file another database or service saved is rebuilt rather than trusted.
  module IndexJournal
    extend self

    # Replay and rebuild hand the thread to other fibers every this many
    # vectors, so opening an index doesn't stall the rest of a server (an
    # insert takes ~4 ms at 1536 dimensions).
    YIELD_EVERY = 16

    # Vectors read per query during a rebuild. Reading in pages keeps no
    # cursor open while other fibers run.
    REBUILD_PAGE = 256

    # Stored vectors compared with a file that doesn't record whose it is,
    # before adopting it (see adopt)
    ADOPT_SAMPLE = 32

    # What a checkpoint file records: the last log entry the index file
    # includes, and whose index it is (files saved before memo recorded
    # that don't say)
    private record Checkpoint, seq : Int64, database_id : String? = nil, service_id : Int64? = nil do
      def from_elsewhere?(database_id : String, service_id : Int64) : Bool
        !@database_id.nil? && (@database_id != database_id || @service_id != service_id)
      end
    end

    # What opening the index took to bring it up to date.
    record Recovery,
      # Logged changes replayed since the file's checkpoint
      replayed : Int32 = 0,
      # Vectors loaded into a rebuilt index (0 if the file was used)
      rebuilt : Int32 = 0,
      # Embeddings found by the one-time migration (see backfill_vectors)
      # with no vector in the index either. Searches can't find them until
      # their sources are indexed again.
      missing : Int32 = 0

    # Lock and open the index at `path`, bringing it up to date with the
    # database. Returns the index, what recovery did, and the lock to hold
    # while the index is open (see USearchIndex.lock).
    #
    # When there's no file at `path` yet, the one at `legacy_path` (where an
    # earlier memo kept it) is adopted if it holds this service's vectors.
    def open(db : DB::Database, path : String, dimensions : Int32, service_id : Int64,
             legacy_path : String? = nil) : {USearch::Index, Recovery, File}
      lock = USearchIndex.lock(path)
      begin
        index, recovery = open_locked(db, path, dimensions, service_id, legacy_path)
        {index, recovery, lock}
      rescue ex
        lock.close
        raise ex
      end
    end

    private def open_locked(db : DB::Database, path : String, dimensions : Int32, service_id : Int64,
                            legacy_path : String?) : {USearch::Index, Recovery}
      q = db.memo_queries
      pruned_through, backfilled = q.get_index_state(service_id) || {0_i64, false}
      index, loaded, checkpoint = load(db, path, dimensions, service_id, legacy_path, backfilled)
      missing = backfilled ? 0 : backfill_vectors(db, index, service_id)

      # The file is usable if its checkpoint falls within the log: not before
      # the pruned entries, and not past the newest one (a file left over
      # from a different database).
      saved_through = checkpoint.try(&.seq) || 0_i64
      latest = {q.max_index_log_seq(service_id), pruned_through}.max
      recovery = if loaded && saved_through >= pruned_through && saved_through <= latest
                   Recovery.new(replayed: replay(db, index, service_id, saved_through), missing: missing)
                 else
                   index.clear if loaded
                   Recovery.new(rebuilt: rebuild(db, index, service_id), missing: missing)
                 end

      if recovery.replayed > 0 || recovery.rebuilt > 0
        checkpoint(db, index, service_id, path)
      end
      {index, recovery}
    end

    # The index file at `path` (or adopted from `legacy_path`), whether it
    # was loaded, and its checkpoint. A file another database or service
    # saved comes back empty, as not loaded.
    private def load(db : DB::Database, path : String, dimensions : Int32, service_id : Int64,
                     legacy_path : String?, backfilled : Bool) : {USearch::Index, Bool, Checkpoint?}
      database_id = Memo::Database.id(db)
      index, loaded = USearchIndex.load_or_create(path, dimensions)
      checkpoint = loaded ? read_checkpoint(path) : nil
      if !loaded && legacy_path && legacy_path != path &&
         (adopted = adopt(db, legacy_path, path, dimensions, service_id, database_id, backfilled))
        index.close
        index, checkpoint = adopted
        loaded = true
      end

      if loaded && checkpoint.try(&.from_elsewhere?(database_id, service_id))
        index.clear
        return {index, false, nil}
      end
      {index, loaded, checkpoint}
    end

    # Store a vector for an embedding row, inside the caller's transaction,
    # and queue it for the index. A row that already has a stored vector
    # (deduplicated content) is skipped; an older row without one gets it.
    def record_vector(
      cnn : DB::Connection,
      pending : USearchIndex::Pending,
      embedding_id : Int64,
      service_id : Int64,
      vector : Array(Float64),
      inserted : Bool,
    ) : Nil
      q = cnn.memo_queries
      return if !inserted && q.get_vector(embedding_id)

      q.upsert_vector(embedding_id, service_id, Storage.encode_vector(vector))
      q.log_index_change(service_id, embedding_id)
      pending.add(embedding_id.to_u64, vector)
    end

    # Record the removal of every service's embedding of `hash`, inside the
    # caller's transaction. Only `service_id`'s index is open here; other
    # services pick up their removals from the log when they next open.
    #
    # Limitation: if another Service has one of those indexes open at the
    # same time, its next save can checkpoint past the removal, leaving a
    # stale vector in that index. Searches filter it out (its embedding row
    # is gone), but it takes up one of the nearest-neighbor slots.
    def record_removals(
      cnn : DB::Connection,
      pending : USearchIndex::Pending,
      hash : Bytes,
      service_id : Int64,
    ) : Nil
      q = cnn.memo_queries
      q.embedding_ids_for_hash(hash).each do |embedding_id, owner_id|
        q.delete_vector(embedding_id)
        q.log_index_change(owner_id, embedding_id)
        pending.remove(embedding_id.to_u64) if owner_id == service_id
      end
    end

    # Save the index and checkpoint the journal: record the last log entry
    # the saved file includes, then prune the log up to it. The file is
    # written on a separate thread (see USearchIndex.save_in_background).
    #
    # The caller must make sure every committed change has been applied to
    # `index`, and keep writers out until this returns, or the checkpoint
    # would claim changes the file lacks.
    def checkpoint(db : DB::Database, index : USearch::Index, service_id : Int64, path : String) : Nil
      q = db.memo_queries
      pruned_through = q.get_index_state(service_id).try(&.[0]) || 0_i64
      seq = {q.max_index_log_seq(service_id), pruned_through}.max

      USearchIndex.save_in_background(index, path)
      write_checkpoint(path, Checkpoint.new(seq, Memo::Database.id(db), service_id))
      return if seq == pruned_through

      Memo::Database.transaction(db) do |cnn|
        cnn.memo_queries.prune_index_log(service_id, seq)
        cnn.memo_queries.set_index_pruned_through(service_id, seq)
      end
    end

    # Bring an open index back in step with the database after a failed
    # update left committed changes out of it: replay the log since the
    # file's checkpoint (or rebuild, if that part is already pruned). Replay
    # is idempotent, so entries the index already has do no harm.
    def catch_up(db : DB::Database, index : USearch::Index, service_id : Int64, path : String) : Nil
      pruned_through = db.memo_queries.get_index_state(service_id).try(&.[0]) || 0_i64
      saved_through = read_checkpoint(path).try(&.seq) || 0_i64
      if saved_through >= pruned_through
        replay(db, index, service_id, saved_through)
      else
        index.clear
        rebuild(db, index, service_id)
      end
    end

    # Apply each embedding logged after `checkpoint` to the index.
    private def replay(db : DB::Database, index : USearch::Index, service_id : Int64, checkpoint : Int64) : Int32
      q = db.memo_queries
      ids = q.index_changes_since(service_id, checkpoint)
      ids.each_with_index(1) do |embedding_id, n|
        if blob = q.get_vector(embedding_id)
          USearchIndex.add(index, embedding_id.to_u64, Storage.decode_vector(blob))
        else
          USearchIndex.remove(index, embedding_id.to_u64)
        end
        Fiber.yield if n % YIELD_EVERY == 0
      end
      ids.size
    end

    # Load every stored vector for the service into an empty index.
    private def rebuild(db : DB::Database, index : USearch::Index, service_id : Int64) : Int32
      q = db.memo_queries
      count = q.count_vectors(service_id)
      return 0 if count == 0

      index.reserve(count)
      added = 0
      after_id = 0_i64
      loop do
        page = q.vectors_after(service_id, after_id, REBUILD_PAGE)
        break if page.empty?
        page.each do |embedding_id, blob|
          USearchIndex.add(index, embedding_id.to_u64, Storage.decode_vector(blob))
          added += 1
          Fiber.yield if added % YIELD_EVERY == 0
        end
        after_id = page.last[0]
      end
      added
    end

    # One-time migration for embeddings stored before memo kept vectors:
    # copy their vectors out of the index. Returns how many the index
    # doesn't have either.
    private def backfill_vectors(db : DB::Database, index : USearch::Index, service_id : Int64) : Int32
      missing = 0
      Memo::Database.transaction(db) do |cnn|
        q = cnn.memo_queries
        q.embedding_ids_without_vectors(service_id).each do |embedding_id|
          if vector = USearchIndex.get_vector(index, embedding_id.to_u64)
            q.upsert_vector(embedding_id, service_id, Storage.encode_vector(vector))
          else
            missing += 1
          end
        end
        q.set_vectors_backfilled(service_id)
      end
      missing
    end

    # Move the index at `legacy_path` to `path` and return it loaded, with
    # its checkpoint, if it's this service's. Earlier versions of memo gave
    # every PostgreSQL database's index, and every index in an index_dir,
    # the same name, so the file may be another database's: one that says
    # whose it is must say this service's, and one that doesn't must hold
    # the first stored vectors. (Before the vectors are stored, the one-time
    # migration in backfill_vectors needs the file, so it's adopted as is.)
    # Returns nil to leave the file alone.
    private def adopt(db : DB::Database, legacy_path : String, path : String, dimensions : Int32,
                      service_id : Int64, database_id : String, backfilled : Bool) : {USearch::Index, Checkpoint?}?
      return unless File.exists?(legacy_path)
      lock = begin
        USearchIndex.lock(legacy_path)
      rescue USearchIndex::InUse
        return
      end

      begin
        checkpoint = read_checkpoint(legacy_path)
        return if checkpoint.try(&.from_elsewhere?(database_id, service_id))

        index, loaded = USearchIndex.load_or_create(legacy_path, dimensions)
        ours = loaded && (!backfilled || holds_stored_vectors?(db, index, service_id))
        unless ours
          index.close
          return
        end

        File.rename(legacy_path, path)
        legacy_checkpoint = USearchIndex.checkpoint_path(legacy_path)
        File.rename(legacy_checkpoint, USearchIndex.checkpoint_path(path)) if File.exists?(legacy_checkpoint)
        File.delete("#{legacy_path}.lock")
        {index, checkpoint}
      ensure
        lock.close
      end
    end

    # Whether the index has the service's first stored vectors under their
    # ids. Another database's file has other vectors under the same ids
    # (every database's ids start at 1).
    private def holds_stored_vectors?(db : DB::Database, index : USearch::Index, service_id : Int64) : Bool
      sample = db.memo_queries.vectors_after(service_id, 0_i64, ADOPT_SAMPLE)
      !sample.empty? && sample.all? do |embedding_id, blob|
        found = USearchIndex.get_vector(index, embedding_id.to_u64)
        found && similar?(found, Storage.decode_vector(blob))
      end
    end

    # Equal up to the index's f16 quantization
    private def similar?(a : Array(Float64), b : Array(Float64)) : Bool
      return false unless a.size == b.size
      dot = norm_a = norm_b = 0.0
      a.each_with_index do |x, i|
        dot += x * b[i]
        norm_a += x * x
        norm_b += b[i] * b[i]
      end
      norm_a > 0 && norm_b > 0 && dot / Math.sqrt(norm_a * norm_b) > 0.999
    end

    private def read_checkpoint(index_path : String) : Checkpoint?
      path = USearchIndex.checkpoint_path(index_path)
      return unless File.exists?(path)
      fields = File.read(path).split
      seq = fields[0]?.try(&.to_i64?) || return
      Checkpoint.new(seq, fields[1]?, fields[2]?.try(&.to_i64?))
    end

    private def write_checkpoint(index_path : String, checkpoint : Checkpoint) : Nil
      path = USearchIndex.checkpoint_path(index_path)
      tmp = "#{path}.tmp"
      File.write(tmp, "#{checkpoint.seq} #{checkpoint.database_id} #{checkpoint.service_id}")
      File.rename(tmp, path)
    end
  end
end
