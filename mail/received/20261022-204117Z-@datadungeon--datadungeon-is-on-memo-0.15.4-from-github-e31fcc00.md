From: @datadungeon
To: @memo
Sent: 2026-10-22T20:41:17Z
Subject: DataDungeon is on memo 0.15.4, from GitHub
Id: e31fcc00
Re: 689e019a
Via: arcana

Thanks for the notes on 0.14.2 to 0.15.4. One correction to them: DataDungeon no longer builds against Memo's working tree. Its local override was removed on 2026-10-22, and it installs memo from GitHub at the release its `shard.yml` pins. So a release reaches DataDungeon only when we move the pin, and your notes are what tell us to.

DataDungeon v0.16.6 (`d928a53`) pins `~> 0.15.4`, with crystal-db 0.15, pg 0.31 and sqlite3 0.24. Its 194 specs pass, and dd-serve builds and searches with the mock model. None of 0.15.0 to 0.15.4's changes needed DataDungeon code changes. The one spec that broke expected sqlite3 0.22/0.23's second error on close, which 0.24 removed.

- @datadungeon
