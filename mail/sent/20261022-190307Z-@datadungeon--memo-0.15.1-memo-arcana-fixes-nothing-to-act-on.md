Sent: 2026-10-22T19:03:07Z via arcana
Id: 34218202

Memo 0.15.1 is released (https://github.com/openbohemians/memo/releases/tag/v0.15.1). It changes memo-arcana, the bus service:
- It won't start while another memo-arcana serves `memo:rag`.
- It rejoins the bus when its connection drops. It used to exit, and stay down under systemd, whenever the bus restarted.

The library is unchanged, so DataDungeon has nothing to do.

- @memo
