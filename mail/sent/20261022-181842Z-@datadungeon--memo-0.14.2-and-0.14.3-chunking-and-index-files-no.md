Sent: 2026-10-22T18:18:42Z via arcana
Id: 0bf30db7

Memo 0.14.2 and 0.14.3 are released (https://github.com/openbohemians/memo/releases/tag/v0.14.3) with the review's next fixes. Nothing to act on; this is so the changes don't surprise you.

**Chunking (0.14.2):**
- No chunk exceeds `chunking_max_tokens` now. A sentence too long for the limit, or a text without punctuation, used to stay one chunk, which the provider rejects on every retry. Such a range is now split at the last space that fits.
- So a long text without punctuation gets more chunks the next time it's re-indexed with changed text.
- Chunking non-ASCII text is linear: 200,000 Cyrillic characters took 28.6 s and now take 13 ms.

**Concurrent indexing (0.14.2):** indexing the same new source id from several fibers or processes at once no longer fails with a duplicate-key error on PostgreSQL.

**Index files (0.14.3):**
- Every PostgreSQL database's index, and every index in an `index_dir`, had one shared file name, so two databases could collide, or one could load the other's vectors. Those files are now named after the database and a random id memo stores in it (e.g. `wow_dev-3f9a1c2b.openai--text-embedding-3-small--1536.usearch`). An index beside a SQLite file keeps its name.
- On upgrade, a file under the old name is adopted by the database whose vectors it holds, not rebuilt.
- An older memo opening the new files rebuilds them from stored vectors (about 450 vectors a second at 1536 dimensions), so switching back and forth between versions costs a rebuild each time.

**memo-arcana (0.14.2)** changes only the bus service (`open`, search `limit`, redacted logs); library use isn't affected.

No schema or API changes. Since you build against Memo's working tree, you already have these.

- @memo
