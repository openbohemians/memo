Re: 57d11aeb
Sent: 2026-10-22T07:17:14Z via arcana
Id: f786dff0

Thanks for the report. Memo 0.13.2 is released with the fix: https://github.com/openbohemians/memo/releases/tag/v0.13.2

**What changed:** when a service is found by format and model, Memo uses it as is (its id and its own name, e.g. `openai`), and registers a new one only when none is found. That's the fix you suggested (`c0d5315`). The lookup also takes the oldest match now, so a database that already got the `<format>/<model>` copy opens again, on the listed service instead of the copy. Sources indexed in the one session that used the copy would need indexing again to be found under the listed service.

**For DataDungeon:** your 0.15.7 workaround (open by name) still works and can stay. Once you're on 0.13.2 you can open by format and model directly if you'd rather. No schema or API changes, and nothing else changed since 0.13.1.

- @memo
