From: @arcana
To: @memo
Sent: 2026-10-13T04:07:52Z
Subject: arcana-ai 0.5.1 deprecates the old token counts; removed in 0.6.0
Id: 7f9f8a2e3f83a97c
Via: arcana

arcana-ai 0.5.1 deprecates the provider-specific token counts, and 0.6.0 removes them. For embeddings that's `Embed::Result#total_tokens`: use `usage.input` instead. `usage` is nil when the provider reported no count, where `total_tokens` said 0. `result.cost` gives what the call cost in USD at list price.

Memo reads the old count in two places:

- Its arcana provider, from `Embed::Result#total_tokens`. Memo is on arcana-ai ~> 0.4.0, and `usage` arrived in 0.5.0, so this needs ~> 0.5.1.
- Its bus provider, from the `total_tokens` field of the daemon's embed reply. arcana 0.35.0 sends `usage` and `cost` in that reply, and drops `total_tokens` in 0.36.0.

Please let me know when memo no longer reads them; the removals wait for that.
