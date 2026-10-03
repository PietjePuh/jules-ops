Repo: PietjePuh/omarchy-toolbelt. Base branch: main. Work on a new branch `bus/v1-mirror-news-actions` and open ONE pull request. Do NOT push to main.

You must NOT ask any questions. Every decision has been made below.

GOAL: make the config mirror and the news feed reachable as BUS ACTIONS, so that a later PR can stop binding their two loopback ports. This PR does NOT remove a port — it adds the bus path alongside the existing one. Port removal is the next PR and it must not happen before the extension consumers have moved.

## Context

- `bin/toolbelt_mirror.py` serves the 15-minute redacted config snapshot on `http://127.0.0.1:3877/snapshot`. Its consumer is `background/modules/toolbelt-mirror.js` in the Toolbelt extension (the bar's Config tab).
- `bin/news.py` serves the news bridge on `http://127.0.0.1:8096` (`news.serve` / `news.serve.stop`, see `bin/news.py:1501`). Its consumer is `background/modules/news-bridge.js` in the Toolbelt extension.
- Every engine here already exposes `python3 bin/<engine>.py act <name> [arg]` through `cmd_act(what, arg)` in `bin/toolbelt_agent.py`. That dispatch is the bus's desktop lane — the gateway calls it. So "become a bus adapter" means "be reachable as an act", not "open a new server".

Protocol reference: `docs/TOOLBELT-BUS-PROTOCOL.md` in THIS repo (byte-identical to the Toolbelt copy) — §2.1 grammar, §2.3 Rule 4 (desktop acts), §6.3 (`positionalString` adapter and the response mapping), §7.2 (honest degradation, normative).

## The changes

1. **Mirror as an act.** Add an act that returns the same redacted snapshot payload `GET :3877/snapshot` returns today — same JSON shape, same redaction, byte-for-byte where possible. Name it per §2.3 Rule 4 under the `svc.` namespace (`svc.mirror.snapshot`). The snapshot generation code must be shared with the HTTP handler, not copy-pasted: one function, two callers.

2. **News as acts.** Same treatment for what `:8096` serves today: the feed read the extension's `news-bridge.js` actually consumes. Keep the existing `news.serve` / `news.serve.stop` acts working — they manage the listener and are not what this replaces. Name the data acts under the `notes.`/`news` mapping the spec's Rule 4 gives them and state the names you chose in the PR body.

3. **Honest degradation (§7.2, normative).** If the underlying data is unavailable — snapshot never generated, feed fetch failed, cache empty because nothing ever populated it — the act returns `{"ok": false, ...}` with a detail naming the cause. It MUST NOT return an empty list, a zeroed object or a synthesised "healthy" payload. `_probe_gateway()` in `bin/toolbelt_agent.py` is the reference pattern: it already returns `{"ok": false, "error": ...}` rather than a fake healthy status. A surface that cannot distinguish "empty result" from "engine down" reports engine down.

4. **`positionalString` shape (§6.3).** Each new act takes at most ONE positional string argument, because that is what `cmd_act(what, arg)` passes. Do not invent a multi-argument act; if an act needs structured input, take a single JSON string and say so in the PR body.

5. **Return shape.** Acts return the `cmd_act` contract (`{ok, action, exit, detail}`) so the gateway's §6.3 response mapping applies unchanged. `detail` stays within the existing 400-char truncation.

## Do not

- Do NOT remove, disable or change the port of `:3877` or `:8096` in this PR. Both keep binding and keep serving exactly as today.
- Do NOT change any response the existing HTTP handlers return — the extension is still reading them.
- Do NOT add a new listener, a new port or a new daemon.
- Do NOT rename an existing act. `bin/toolbelt_agent.py`'s act names are load-bearing for the alias map (§2.3 Rule 4 states no act name changes).

## Verification — paste the output in the PR body

1. `python3 bin/toolbelt_agent.py act svc.mirror.snapshot` (and each news act you added) returns `ok: true` with the same payload the corresponding HTTP endpoint returns, and `ok: false` with a named cause when the data is genuinely unavailable. Show both, with the HTTP response next to the act response so the equivalence is visible.
2. Add a `test/test_*.py` covering both the success and the unavailable path for each new act, asserting the unavailable path is NOT an empty-but-ok payload.
3. Run the full suite: `python3 test/run_all.py` (or, if that runner is not yet on main, every `test/test_*.py` individually) and paste the summary.

## Repository constraint — v2 surface freeze

This repository is under the **v2 surface freeze**. Do not add a new `*-hub/` directory or standalone hub page, a new `background/modules/` engine that polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a `sidepanel/tools-catalog.json` entry with no counterpart in `omarchy-toolbelt/catalog/tools.json`. CI enforces this (`tests/regression/v2-surface-freeze-ratchet.test.js` in Toolbelt) and your PR will be red. Prefer folding your change into an existing surface. Do **not** add a `// ratchet-ok:` comment to get around the gate — that hatch is for reviewed exceptions only, and using it without review gets the PR closed.
