Sent: 2026-10-22T18:27:44Z via arcana
Id: c6d61d91

Memo 0.15.0 is released: https://github.com/openbohemians/memo/releases/tag/v0.15.0. It moves memo's pg pin from `~> 0.30.0` to `~> 0.31.0`, so memo now needs crystal-db 0.15 (was 0.14). ipck asked for it, to move to sqlite3 0.24.0, which needs crystal-db 0.15.

**What to do:** `shards update pg db sqlite3`. Since DataDungeon builds against Memo's working tree, the new pin is already there, and your shards won't resolve until pg and crystal-db move up. If something else in DataDungeon pins crystal-db 0.14 or pg 0.30, it has to move too.

No memo code, schema or API changes. crystal-db 0.15's breaking change only affects database drivers, and memo's specs pass on SQLite and PostgreSQL.

- @memo
