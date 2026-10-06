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
  module IndexJournal
    extend self

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

    # Open the index at `path`, bringing it up to date with the database.
    def open(db : DB::Database, path : String, dimensions : Int32, service_id : Int64) : {USearch::Index, Recovery}
      index, loaded = USearchIndex.load_or_create(path, dimensions)
      q = db.memo_queries
      pruned_through, backfilled = q.get_index_state(service_id) || {0_i64, false}
      missing = backfilled ? 0 : backfill_vectors(db, index, service_id)

      # The file is usable if its checkpoint falls within the log: not before
      # the pruned entries, and not past the newest one (a file left over
      # from a different database).
      saved_through = loaded ? (read_checkpoint(path) || 0_i64) : 0_i64
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
    # the saved file includes, then prune the log up to it.
    #
    # The caller must make sure every committed change has been applied to
    # `index`, or the checkpoint would claim changes the file lacks.
    def checkpoint(db : DB::Database, index : USearch::Index, service_id : Int64, path : String) : Nil
      q = db.memo_queries
      pruned_through = q.get_index_state(service_id).try(&.[0]) || 0_i64
      seq = {q.max_index_log_seq(service_id), pruned_through}.max

      USearchIndex.save(index, path)
      write_checkpoint(path, seq)
      return if seq == pruned_through

      Memo::Database.transaction(db) do |cnn|
        cnn.memo_queries.prune_index_log(service_id, seq)
        cnn.memo_queries.set_index_pruned_through(service_id, seq)
      end
    end

    # Apply each embedding logged after `checkpoint` to the index.
    private def replay(db : DB::Database, index : USearch::Index, service_id : Int64, checkpoint : Int64) : Int32
      q = db.memo_queries
      ids = q.index_changes_since(service_id, checkpoint)
      ids.each do |embedding_id|
        if blob = q.get_vector(embedding_id)
          USearchIndex.add(index, embedding_id.to_u64, Storage.decode_vector(blob))
        else
          USearchIndex.remove(index, embedding_id.to_u64)
        end
      end
      ids.size
    end

    # Load every stored vector for the service into an empty index.
    private def rebuild(db : DB::Database, index : USearch::Index, service_id : Int64) : Int32
      q = db.memo_queries
      count = q.count_vectors(service_id)
      return 0 if count == 0

      index.reserve(count)
      q.each_vector(service_id) do |embedding_id, blob|
        USearchIndex.add(index, embedding_id.to_u64, Storage.decode_vector(blob))
      end
      count.to_i32
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

    private def read_checkpoint(index_path : String) : Int64?
      path = USearchIndex.checkpoint_path(index_path)
      File.exists?(path) ? File.read(path).strip.to_i64? : nil
    end

    private def write_checkpoint(index_path : String, seq : Int64) : Nil
      path = USearchIndex.checkpoint_path(index_path)
      tmp = "#{path}.tmp"
      File.write(tmp, seq.to_s)
      File.rename(tmp, path)
    end
  end
end
