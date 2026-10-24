# Roadmap and decisions

*Updated 2026-10-23*

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
- **Who may use a namespace** (parked by the user, 2026-10-23): review finding 14.
  memo-arcana trusts its bus (SECURITY.md): any client can read, write and delete in any
  namespace, and `from` is whatever the sender wrote. Since arcana 0.37 the bus marks a
  message `verified` when its sender proves it holds `from` (arcana-core 0.21: `Arcana::Key`,
  `Envelope#verified`, `Envelope#signer`). The plan: an optional `allow:` line per namespace
  in `namespaces.yaml` naming the senders that may use it. It gates every action on the
  namespace, reads included (the user chose that, 2026-10-23), and a namespace without one
  stays open. memo-arcana joins with a key, its path from an environment variable, which
  also holds `memo:rag` against other clients. It needs arcana-core ~> 0.21.0, so it's a
  minor release. **Pick it up once wow signs its messages**: wow's own WebSocket client
  doesn't yet, so `allow: wow` would lock wow out. Once a key holds `memo:rag`, the address
  stays listed while memo-arcana is down, so a sync call times out instead of failing with
  "no mailbox".
- **Full-text filter** (idea): a `match` filter runs FTS5's `MATCH` once per candidate,
  as on 0.12. Constraining it by rowid could cut that, if it shows up in profiles.
