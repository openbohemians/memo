# Status

*Updated 2026-10-22*

- **0.15.0 released 2026-10-22** (tag `v0.15.0` at `9f0d15e`): requires pg ~> 0.31.0 and so
  crystal-db 0.15 (`31da868`), which `@ipck` asked for to reach sqlite3 0.24.0. A minor bump
  because library users must move to crystal-db 0.15 too. No code changes. `@ipck` and
  `@datadungeon` were told the same day, and goldfish got a note in its inbox (`mail/sent/`).
- **0.14.3 released 2026-10-22** (tag `v0.14.3` at `288eca5`): every PostgreSQL database's
  index, and every index in an `index_dir`, had one shared file name. Those files are now
  named `<database name>-<id8>.…`, with a random id kept in `memo_meta.database_id`, and the
  checkpoint records the database and service ids (`9386a56`). On upgrade, a file under the
  old name is adopted by the database whose first 32 stored vectors it holds. That was
  checked live against files 0.14.2 wrote: one database adopts its file, and with two that
  shared it, the owner adopts it and the other rebuilds. A rebuild adds about 450
  vectors/s at 1536 dimensions. An older memo reading the new checkpoints rebuilds.
  `@datadungeon` and `@ipck` were told of 0.14.2 and 0.14.3 the same day (`mail/sent/`).
- **0.14.2 released 2026-10-22** (tag `v0.14.2` at `f4f8a57`): the review's second batch.
  Chunking is linear for non-ASCII text, and no chunk exceeds `max_tokens` (`02f6baa`). A
  new source id resolves safely under concurrent writers (`c3f93d1`). memo-arcana
  (`6536c36`): `open` registers a namespace the config doesn't list only with
  `MEMO_BUS_OPEN=1`. The user chose off by default (2026-10-22), and will list wow in the
  deployed `namespaces.yaml`, since wow opens its namespace over the bus. Bus-opened
  namespaces never get the server's API key, `open` can't redirect a registered namespace,
  search `limit` is capped at 1000, and database passwords are redacted in the startup log
  and error replies. Library users have nothing to act on.
- **0.14.1 released 2026-10-22** (tag `v0.14.1` at `4e2b072`): the first batch of fixes from
  an independent review (Codex, 2026-10-22). Search filters now apply to every result, which
  matters because sources sharing a text used to leak past them (`1e54b50`). Unresolved id
  filters find nothing. Queue work is written only while current, and deletes cancel it
  (`4da6638`). `@datadungeon` and `@ipck` were told the same day (`mail/sent/`). More batches
  are coming; the user agreed to fix the findings in order and release in batches.
- **0.14.0 released 2026-10-22** (tag `v0.14.0` at `7717f7a`): requires arcana-core
  ~> 0.20.0 and arcana-ai ~> 0.6.1 (`e901e59`). A minor bump because library users must
  move to the same arcana. No code, schema or API changes. `@datadungeon` and `@ipck`
  were told on 2026-10-22 (`mail/sent/`), and goldfish got a note in its inbox the same day.
- **0.13.2 released 2026-10-22** (tag `v0.13.2` at `c3db595`), ahead of a deployment:
  opening a service by format and model uses the service found instead of adding a
  `<format>/<model>` copy, which made the next such open raise "more than one row"
  (`c0d5315`). `@datadungeon` reported it on 2026-10-20 (`mail/received/`) and works
  around it by opening by name (DataDungeon 0.15.7). Told of the fix and release on 2026-10-22 (`mail/sent/`).
- **0.13.1 released 2026-10-14** (tag `v0.13.1` at `60833b6`): token counts come from
  arcana-ai's `usage` (`6794fea`). It needs arcana-ai ~> 0.5.1. No schema or API changes.
- **0.13.0 released 2026-10-11** (tag `v0.13.0` at `5f51edd`, with Arch and Debian
  packages). It adds the journaled, crash-safe index, concurrent memo-arcana, faster
  filtered search, and content-addressed storage (PR #5, `f1fa8ef`). The CHANGELOG has
  the details.
- The `v0.13.0` tag first pointed at `bde4664`: ipck's agent created it on 2026-10-10
  to make `memo ~> 0.13.0` resolve, before any release. The user agreed to move it to the
  release commit (2026-10-11).
- The content-addressed migration is one-way, and runs once when a database is first
  opened. `memo_meta.schema_version` is 1. A database from a newer memo is refused.

## Open

- **goldfish**: `Memory#about` still reads `memo_texts`. It breaks once goldfish builds
  against 0.13. The fix went to goldfish's inbox on 2026-10-11 (`mail/sent/`); goldfish has
  no agent, so the user makes the change. Still open on 2026-10-22: goldfish follows memo's
  `main`, so its next `shards update` brings 0.15.0, which also needs arcana-core 0.20 and
  crystal-db 0.15. Its no-key path opens memo with `format: "mock"` and no model, which memo
  has refused since `0d2815e`. The two 2026-10-22 inbox notes (0.14.0 and 0.15.0) cover these.
- **Old token counts**: **fixed in `6794fea`, released in 0.13.1** (2026-10-14).
  memo reads `usage.input` in its arcana and bus providers and requires arcana-ai ~> 0.5.1.
  `@arcana` asked for this on 2026-10-13 (`mail/received/`), and was told it's done on
  2026-10-14, and again when 0.13.1 was released. 0.13.0 is safe from the removals: it's pinned to arcana-ai ~> 0.4.0,
  and its bus provider treats a missing `total_tokens` as 0.
- **Consumers need arcana-ai 0.5**: DataDungeon, copious, ipck and justice are on arcana-ai
  0.4.0 and build against memo's working tree, so they fail until `shards update
  arcana-ai`. Both agents were told on 2026-10-14 (`mail/sent/`).
- **arcana pins lag**: **fixed in `e901e59`, released in 0.14.0** (2026-10-22). memo had
  pinned arcana-core ~> 0.16.0 and arcana-ai ~> 0.5.1 while 0.20.0 and 0.6.1 were out, so a
  project on the newer ones couldn't resolve it; the user said it needed sorting before the
  deployment. No code changed, and memo-arcana ran live against arcana 0.36.2.
