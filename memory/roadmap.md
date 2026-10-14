# Roadmap and decisions

*Updated 2026-10-14*

- **Attributes and labels stay out of memo** (the user decided, 2026-10-10). Artistry is the
  metadata system (schema-checked fields, expression indexes, tags, links). A separate
  integration package depending on both will connect them, and artistry will get a
  Postgres port. The longest-prefix key trick becomes composite expression indexes in
  artistry. memo's part is its documented SQL contract ("Reading memo's tables" in the
  README) and `sql_where`, whose narrow and broad filters search already plans for.
  Open for that package: artistry's copy-on-write updates give each version a new id
  (memo sources need a stable key), and artistry's cascades don't reach memo's tables.
- **Option C, joining in search** (open): optional `sql_join` and `sql_select` for
  `Service.search`, so apps sharing memo's database get their own columns back with the
  results. Today wow runs a second batched `IN` query. Needs SQLite (ATTACH) and Postgres.
- **pgvector** (open): USearch keeps every vector in RAM (about 4 GB at 100K
  embeddings of 1536 dimensions). Past that, or with several app servers, add a pgvector
  adapter beside USearch, chosen per namespace. It would also make memo-arcana stateless.
  Wait for real load numbers (infocomic's demo) first.
- **Full-text filter** (idea): a `match` filter runs FTS5's `MATCH` once per candidate,
  as on 0.12. Constraining it by rowid could cut that, if it shows up in profiles.
