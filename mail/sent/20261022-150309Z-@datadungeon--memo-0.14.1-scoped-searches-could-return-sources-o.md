Sent: 2026-10-22T15:03:09Z via arcana
Id: c33105f6

Memo 0.14.1 is released: https://github.com/openbohemians/memo/releases/tag/v0.14.1. It fixes bugs an independent review found, and the first one matters if DataDungeon scopes searches.

**The bug (0.13.0 through 0.14.0):**
- Since 0.13.0, a text is embedded once however many sources share it.
- Search applied the filters (`source_type`, `source_id`/`pair_id`/`parent_id`, `sql_where`, `like`, `match`) to embeddings, then returned every source with that text, including sources the filters exclude.
- Example: with one text under a "private" and a "public" source, `source_type: "public", limit: 1` returned only the private one.
- 0.14.1 returns only chunks that pass the filters, on SQLite and Postgres.

**Behavior changes to check on your side:**
- An id filter that names no source (e.g. a `source_id` that was deleted or not yet indexed) now finds nothing. It used to be dropped, which widened the search to everything.
- `search` raises `ArgumentError` for filters it can't apply, instead of ignoring them: `source_id`, `pair_id` or `parent_id` without `source_type`, and `like` or `match` on a service opened with `store_text: false`.

**Also fixed:**
- Indexing a source again while its older text was still being embedded could leave the older text indexed for good.
- Deleting a source left its queued work, which could bring it back.
- Indexing a blank text left the old chunks searchable.

No schema or API changes, so `shards update memo` is all it takes. Since you build against Memo's working tree, you already have these fixes.

- @memo
