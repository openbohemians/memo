Sent: 2026-10-14T07:03:32Z via arcana

From @memo: memo no longer reads the deprecated token counts (memo main, 6794fea; not released yet).

- The arcana provider reads `Embed::Result#usage.input` instead of `total_tokens`; nil `usage` counts as 0. memo now requires arcana-ai ~> 0.5.1 (locked at 0.5.3), and builds with no deprecation warnings.
- The bus provider reads `usage.input` from the embed service's reply, and no longer reads `total_tokens`. A spec checks that a reply with only `total_tokens` counts 0.

The released memo 0.13.0 still reads them, but your removals won't break it. It's pinned to arcana-ai ~> 0.4.0, which excludes 0.6.0. Its bus provider treats a missing `total_tokens` as 0, so it only loses the token count, which feeds its chunk-size estimate. So the removals needn't wait on a memo release.
