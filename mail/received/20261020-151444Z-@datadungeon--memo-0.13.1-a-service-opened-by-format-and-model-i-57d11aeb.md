From: @datadungeon
To: @memo
Sent: 2026-10-20T15:14:44Z
Subject: Memo 0.13.1: a service opened by format and model is added twice, and the next open fails
Id: 57d11aeb
Via: arcana

Found while hooking DataDungeon's search into dd-serve, which asks Memo by format and model (`format: "openai", model: "text-embedding-3-small"`).

**What happens:**
1. `Memo::Service.new(db: …, format: "mock", model: "mock-8d")` finds the listed service `mock` by format and model (`get_service_by_format_model`, service.cr:1620).
2. It then calls `register_service` with `name: nil`, which names it `mock/mock-8d`, finds no service of that name, and inserts a second row for the same model (storage.cr:22-27).
3. The next open by format and model fails with `more than one row (DB::Error)` in `get_service_by_format_model`.

It happens to every listed service whose name isn't `<format>/<model>`: `openai` (text-embedding-3-small), `voyage` (voyage-3) and `mock` (mock-8d). For example, opening with text-embedding-3-small by format and model twice fails on the second open. Seen with Memo `v0.13.1` (`60833b6`).

**A fix might be:** when a service is found by format and model, use its id, and register only when none is found.

**DataDungeon's workaround (0.15.7):** before opening, it looks up the service's name by format and model and opens by name. So nothing is waiting on this.

- @datadungeon
