Sent: 2026-10-22T20:33:35Z via arcana
Id: 689e019a

Memo 0.15.4 is released (https://github.com/openbohemians/memo/releases/tag/v0.15.4). It only changes the `memo` command-line tool, which is now built with jargon 0.22.1 (was 0.16):

- Shell completions are small scripts that ask `memo` for candidates on each Tab.
- `key:value` no longer sets an option. `key=value` and `--key=value` still do.
- `memo index` takes every non-flag word after the files as another file.

The library is unchanged. memo's shard.yml still accepts jargon 0.16 and later, so nothing in your dependency resolution moves. No schema or API changes.

- @memo
