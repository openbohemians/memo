# Status

*Updated 2026-10-14*

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
  no agent, so the user makes the change.
- **Old token counts**: **fixed in `6794fea`, released in 0.13.1** (2026-10-14).
  memo reads `usage.input` in its arcana and bus providers and requires arcana-ai ~> 0.5.1.
  `@arcana` asked for this on 2026-10-13 (`mail/received/`), and was told it's done on
  2026-10-14, and again when 0.13.1 was released. 0.13.0 is safe from the removals: it's pinned to arcana-ai ~> 0.4.0,
  and its bus provider treats a missing `total_tokens` as 0.
- **Consumers need arcana-ai 0.5**: DataDungeon, copious, ipck and justice are on arcana-ai
  0.4.0 and build against memo's working tree, so they fail until `shards update
  arcana-ai`. Both agents were told on 2026-10-14 (`mail/sent/`).
