# Correspondents

*Updated 2026-10-14*

The projects memo's agent corresponds with, and how each uses memo. Library users run
`Memo::Service` in their own process. Bus users go through memo-arcana (`memo:rag`).

| Address | Uses memo | Notes |
|---|---|---|
| `@datadungeon` | library | Asset store; `SemanticIndex` filters searches with `sql_where` over its own key index. Updated for 0.13 on 2026-10-11: four spec queries now read `memo_contents`, and its shards are on arcana-ai/arcana-core 0.16. It keeps its own unchanged-text pre-check, since enqueue still writes a queue row. |
| `@ipck` | library | copious, ipck and justice share one SQLite database with artistry and join memo's tables in `sql_where`. Requires `memo ~> 0.13.0`; all specs passed against 0.13 (2026-10-11). Plans: copious will index only curated records (memories, notes, summaries, concerns), not raw events, and later memo moves into copious's memory plugin. |
| `@infocomics` | via DataDungeon | The launch product. A public demo is planned, which will measure real load before Postgres + pgvector is considered (see [roadmap.md](roadmap.md)). |
| goldfish | library | No agent: mail goes to its `.ai/mail/inbox/`, and the user acts on it. |
| wow | bus | Sends `ns` with every request. Hydrates results with a second query (see Option C in [roadmap.md](roadmap.md)). |
| `@arcana` | dependency | The bus and arcana-ai. 2026-10-13: arcana-ai 0.5.1 deprecates the old token counts, removed in 0.6.0. |

## How the user wants mail handled

- A notice another project *has* to get, such as a breaking change to memo's schema, SQL
  contract or required dependencies, or a data migration, goes out without asking. Tell the
  user what was sent. Requests, proposals and pushback wait for the user (2026-10-10).
- To learn how a change affects another project, ask its agent. Don't dig through its
  code or run its specs (2026-10-10).
- Never change another project's code: ask its agent for the change.
