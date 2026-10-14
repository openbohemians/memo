# Status

*Updated 2026-10-14*

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
- **Stop reading the old token counts** (asked by `@arcana` 2026-10-13, not started).
  arcana-ai 0.5.1 deprecates them and 0.6.0 removes them. Arcana's removals wait for memo,
  so tell `@arcana` when it's done.
  - `src/memo/providers/arcana.cr:49` reads `Embed::Result#total_tokens`. Use
    `usage.input` instead, which is nil when the provider reported no count (the old field
    said 0). This needs `arcana-ai ~> 0.5.1`; memo is on `~> 0.4.0`.
  - `src/memo/providers/bus.cr:81` reads `total_tokens` from the daemon's embed reply.
    arcana 0.35.0 sends `usage` and `cost` there, and 0.36.0 drops `total_tokens`.
  - `result.cost` gives the call's cost in USD at list price, if memo wants it.
  The message is in `mail/received/20261013-040752Z-@arcana--arcana-ai-token-counts-7f9f8a2e.md`.
