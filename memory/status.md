# Status

*Updated 2026-10-23*

- **0.15.5 released 2026-10-23** (tag `v0.15.5` at `984bd1b`): memo names jargon by its new
  home, `openbohemians/jargon.cr` (`fa6ed05`). Shards refuses one shard named from two
  sources, so `@ipck` couldn't take artistry 0.12.0, which names the new one, until a memo
  release did; it asked on 2026-10-24 UTC, and the user chose to release before finding 14's
  work (2026-10-23). `@ipck` (covering 0.15.3 to 0.15.5) and `@datadungeon` were told the
  same day (`mail/sent/`).
- **0.15.4 released 2026-10-22** (tag `v0.15.4` at `1c6a326`): the CLI is built with jargon
  0.22.1, at the user's request (`99bb95c`, `b5f47e7`). jargon's completion scripts now call
  the program's hidden `__complete` verb, so `bin/memo.cr` calls `handle_completion` before
  `parse`. `shard.yml` keeps `~> 0.16`: only the CLI uses jargon, and ipck pins jargon
  `~> 0.16.0` (copious does through artistry, which uses jargon as a schema validator), so a
  higher floor would keep them from resolving memo. A mistyped option value gets two errors;
  that's jargon's, and the user said jargon is fixing it (2026-10-22). `@datadungeon` was
  told the same day (`mail/sent/`).
- **0.15.3 released 2026-10-22** (tag `v0.15.3` at `6bd5d44`): `memo index -r` fixes, the
  last of the review's findings except 14 (`f509649`). The walk skips symlinks inside the
  tree. Files are keyed by real absolute path, and a record under the old relative key is
  taken over, keeping its id, when its file is indexed again (checked against a 0.15.2
  database). A run where text moves between files no longer fails for good. Indexing a
  directory removes the files under it that it no longer finds. No library consumer calls
  file indexing (checked 2026-10-22), so only the CLI's output changed. Specs that index
  files must require memo before `spec`: the magic shard closes libmagic in an `at_exit`.
  The CLI's `-s mock` can't index: it has no chunk-size option, and 2000 exceeds the mock's
  100 (any service under 2000 tokens is refused the same way). `@datadungeon` was told the
  same day (`mail/sent/`).
- **0.15.2 released 2026-10-22** (tag `v0.15.2` at `05a0bec`): the review's later findings,
  which the user asked to fix in full. `use_service` switches the query cache, chunking and
  index together (`9f23a1c`). Opening by format and model uses the stored `base_url`
  (`562633f`). `delete_service` works on PostgreSQL and spares other services' chunks and
  held lock files (`6df4d15`). Clustering works on PostgreSQL (`568452e`). Another service's
  logged removals are applied before a checkpoint, and replay looks vectors up per service,
  since SQLite reuses freed embedding rowids (`44aebdc`). memo-arcana caps chunking at 100 only
  for mock namespaces (`9a0f6e1`). `@datadungeon` and `@ipck` were told the same day
  (`mail/sent/`).
- **0.15.1 released 2026-10-22** (tag `v0.15.1` at `64791fb`), both asked for by the user that
  day: memo-arcana won't start while another one answers at `memo:rag` (`dfe1c26`), and it
  rejoins the bus when its connection drops (`ed8e1a9`). It used to exit 0 when the bus went
  away, so systemd's `Restart=on-failure` left it stopped after any bus restart. Both checked
  live against a private relay. Library users have nothing to act on. `@datadungeon` was told
  the same day (`mail/sent/`); the user wants it told of every release.
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

- **Arcana owner tokens and keys**: arcana-core 0.20.1 (bus 0.36.4) lets a client claim its
  address with an owner token at `join`. arcana-core 0.21.0 (bus 0.37.0) adds a key per
  project; the bus stamps a message `verified` when the sender proves it holds `from`.
  memo-arcana uses neither yet; adopting 0.21 would raise memo's arcana-core pin. Plan for
  one change: an address held by a token or key stays listed after its client disconnects,
  and its mailbox keeps collecting, so while memo-arcana is down a sync call to `memo:rag`
  waits out its timeout instead of failing with "no mailbox" (the `already_running?` probe
  still works). The bus wasn't on 0.36.4 or 0.37.0 yet on 2026-10-22. **Open, waiting for
  the user.**
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
- **Consumers need arcana-ai 0.5**: **closed.** DataDungeon, copious, ipck and justice were on
  arcana-ai 0.4.0 and built against memo's working tree; both agents were told on 2026-10-14
  (`mail/sent/`). Both now build against memo's releases: DataDungeon is on 0.15.4
  (2026-10-22) and ipck on 0.15.2 (2026-10-23).
- **arcana pins lag**: **fixed in `e901e59`, released in 0.14.0** (2026-10-22). memo had
  pinned arcana-core ~> 0.16.0 and arcana-ai ~> 0.5.1 while 0.20.0 and 0.6.1 were out, so a
  project on the newer ones couldn't resolve it; the user said it needed sorting before the
  deployment. No code changed, and memo-arcana ran live against arcana 0.36.2.
