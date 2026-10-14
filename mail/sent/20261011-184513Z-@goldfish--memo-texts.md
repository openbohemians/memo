Sent: 2026-10-11T18:45:13Z via inbox

memo 0.13.0 drops the `memo_texts` table, and goldfish reads it directly.

WHAT BREAKS: `Memory#about` in src/goldfish/memory.cr (lines 102-113) joins `memo_texts`:

    "JOIN memo_texts t ON t.source_id = s.id "

Once goldfish builds against memo 0.13.0, that query fails with "no such table: memo_texts".

THE FIX: memo now stores each distinct text once, in `memo_contents`, and each source points at its latest text through `memo_sources.content_id`. Change that line to:

    "JOIN memo_contents t ON t.id = s.content_id "

`t.content` stays the same, and so does the rest of the query (`s.external_int = m.id`). `identity_scope_sql` and the search calls need no change: `c.source_id` in `sql_where` means what it did.

ALSO WORTH KNOWING:
- The first open of an existing goldfish database with memo 0.13.0 migrates it once, in one transaction, and the migration is one-way. Back up the database first if its memories matter.
- memo moved to github.com/openbohemians/memo (the old trans/memo URLs redirect). goldfish's shard.yml can point there, with `version: ~> 0.13.0`.
- Remembering the same text twice now stores it once and costs one embedding call, not two.

Details: memo commit f1fa8ef (PR #5) and the 0.13.0 entry in memo's CHANGELOG, including "Reading memo's tables" in its README.
