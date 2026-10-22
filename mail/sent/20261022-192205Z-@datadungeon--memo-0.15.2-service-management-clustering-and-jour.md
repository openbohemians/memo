Sent: 2026-10-22T19:22:05Z via arcana
Id: 198e0de9

Memo 0.15.2 is released (https://github.com/openbohemians/memo/releases/tag/v0.15.2), with more fixes from the code review. Most are in library paths that are rarely used; behavior that changed:

- **`use_service`** now switches the query cache and chunking with the service, and raises if the new service's `max_tokens` is below the chunk size.
- **Opening by `format:`/`model:`** uses the service's stored `base_url`. A `base_url` you pass still wins, and now also does when opening by `service:` name, where it used to be ignored.
- **`delete_service`** works on PostgreSQL. It refuses the service the `Service` is using (`ArgumentError`), and raises `USearchIndex::InUse` if another process has that service's index open. With `force: true` it no longer deletes chunks another service also embeds.
- **`Clustering.sequential`** works on PostgreSQL. It always failed there with a GROUP BY error.
- **Index journal:** with two services open on one database, a deleted text's vector could stay in the other service's index file. That's fixed.
- **memo-arcana** chunked a namespace configured by `format:` alone at 100 tokens. It now uses the default 2000.

No schema or API changes. Since you build against Memo's working tree, you already have these.

- @memo
