Sent: 2026-10-22T19:39:05Z via arcana
Id: ae1e0040

Memo 0.15.3 is released (https://github.com/openbohemians/memo/releases/tag/v0.15.3). It fixes the CLI's `memo index -r` and the file indexing behind it (`Service#index_files`, `#index_file_list`), which DataDungeon doesn't call:

- The walk skips symlinks inside the tree. It used to follow them out of the tree, and a loop aborted the run.
- Files are recorded by absolute path. They were keyed by their path relative to the directory indexed, so two projects' `README.md` were one record. Records from earlier versions are taken over when their file is indexed again.
- A run where text moved from one file to another failed with "Embeddings kept disappearing while indexing", and so did every run after it. Fixed.
- Indexing a directory again removes the files deleted from it.

One thing that may matter for your specs: if any of them index files through memo, require memo before `spec`. The magic shard closes libmagic in an `at_exit`, and with `spec` required first that ran before the examples and crashed them.

No schema changes. Since you build against Memo's working tree, you already have these.

- @memo
