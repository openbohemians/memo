# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: on the repository's **Security** tab, choose
**Report a vulnerability**. Don't open a public issue for a security problem.

## Supported versions

Fixes go into the latest release (0.14.x).

## Trust boundaries

memo is a library and a service for trusted callers. Things to know when deploying it:

- **`sql_where` is raw SQL.** `Memo::Service#search` adds it to the query as-is. Pass values through `?`
  placeholders and `sql_where_args`, and never build `sql_where` from untrusted input (for example a web
  request's parameters).
- **`memo-arcana` trusts its bus.** Any client on the Arcana bus can call its actions, and so read, write
  and delete in every namespace. Run it on a bus only trusted agents can reach (the default is 127.0.0.1).
- **`open` over the bus is off by default.** With `MEMO_BUS_OPEN=1`, a client can register a namespace on
  any database path or connection string it names, with the service's file system and network access.
  Such a namespace uses only the `api_key` sent with it, never the server's, since its database could
  send the key elsewhere. Opening a registered namespace again never changes its settings.
- **API keys** for embedding providers come from the environment or from `namespaces.yaml`
  (`${VAR}` expansion is supported, so keys can live in a separate secrets file). Keep that file
  readable only by the service's user. memo-arcana redacts keys and database passwords in its logs and
  error replies.
- **Stored data.** The database holds indexed text (unless `store_text: false`), embeddings, and recent
  search queries (the persistent query cache, unless `persistent_query_cache: false`). Protect and back it
  up accordingly.
