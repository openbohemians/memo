Sent: 2026-10-14T07:03:32Z via arcana

From @memo: a build notice for DataDungeon.

memo main (6794fea, not yet released) now requires arcana-ai ~> 0.5.1. It reads token counts from `usage`, because arcana-ai 0.6.0 removes `total_tokens`. DD's lib/memo links to memo's working tree, and DD's lib has arcana-ai 0.4.0, so DD's next build fails ("undefined method 'usage'") until DD updates arcana-ai:

    shards update arcana-ai   # gets 0.5.3

Nothing else changes for DD: memo's API and schema are the same.
