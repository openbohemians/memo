# Correspondents

*Updated 2026-10-23*

The projects memo's agent corresponds with, and how each uses memo. Library users run
`Memo::Service` in their own process. Bus users go through memo-arcana (`memo:rag`).

| Address | Uses memo | Notes |
|---|---|---|
| `@datadungeon` | library | Asset store; `SemanticIndex` filters searches with `sql_where` over its own key index. Since 2026-10-22 it builds memo from GitHub at the release its `shard.yml` pins, with no local override, so a release reaches it only when it moves the pin, and memo's release notes are what prompt that. DataDungeon v0.16.6 (`d928a53`) pins `~> 0.15.4`, with crystal-db 0.15, pg 0.31 and sqlite3 0.24 (2026-10-22). It keeps its own unchanged-text pre-check, since enqueue still writes a queue row. |
| `@ipck` | library | copious, ipck and justice share one SQLite database with artistry and join memo's tables in `sql_where`. It builds against memo's GitHub releases (committed `shard.lock`, no path overrides), and was on 0.15.2 with sqlite3 0.24 on 2026-10-23. jargon reaches it through both memo and artistry, so they must name the same jargon source. Plans: copious will index only curated records (memories, notes, summaries, concerns), not raw events, and later memo moves into copious's memory plugin. |
| `@infocomics` | via DataDungeon | The launch product. A public demo is planned, which will measure real load before Postgres + pgvector is considered (see [roadmap.md](roadmap.md)). |
| goldfish | library | No agent: mail goes to its `.ai/mail/inbox/`, and the user acts on it. |
| wow | bus | Sends `ns` with every request. Hydrates results with a second query (see Option C in [roadmap.md](roadmap.md)). |
| `@arcana` | dependency | The bus and arcana-ai. 2026-10-13: asked memo to stop reading the old token counts before their removal (see [status.md](status.md)). 2026-10-22: announced owner tokens at join and signed project keys (see status.md, Open). |

## How the user wants mail handled

- A notice another project *has* to get, such as a breaking change to memo's schema, SQL
  contract or required dependencies, or a data migration, goes out without asking. Tell the
  user what was sent. Requests, proposals and pushback wait for the user (2026-10-10).
- To learn how a change affects another project, ask its agent. Don't dig through its
  code or run its specs (2026-10-10).
- Never change another project's code: ask its agent for the change.
