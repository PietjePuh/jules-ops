Repo: PietjePuh/Toolbelt. Base branch: main. Work on a new branch `bus/v1-desktop-lane` and open ONE pull request. Do NOT push to main.

PREREQUISITE: TIM-18 slice 1 (`POST /api/v1/bus` + the v1 envelope in `gateway/extension-rpc.js`) must be on main. If it is not, stop and say so — do not re-implement it.

You must NOT ask any questions. Every decision has been made below.

GOAL: build the missing direction. Today the desktop can invoke a browser action (the long-poll lane already works). This PR lets a browser surface invoke a DESKTOP engine action. This is spec §6.3 — one adapter plus an allowlist, not 80 integrations.

## Read first

`docs/TOOLBELT-BUS-PROTOCOL.md` §6.3 (the whole section, including the response mapping table), §7.1, §7.2 (honest degradation, normative), §9.1. Schema: `docs/toolbelt-bus.schema.json`.

The desktop engines are uniformly `python3 bin/<engine>.py act <name> [arg]`, dispatched through `cmd_act(what, arg)` in `omarchy-toolbelt/bin/toolbelt_agent.py`. `bin/toolbelt_agent.py` already holds the gateway key and already calls `http://127.0.0.1:3847/health` — the credential path exists. **No change to the omarchy-toolbelt repo is required by this PR.**

## The changes — all in `gateway/`

1. **Desktop lane.** The gateway invokes `python3 bin/toolbelt_agent.py act <name> [arg]` on the host (or the agent's socket, if you choose one — state which you picked and why in the PR body). Resolve the agent path from configuration, not a hardcoded absolute path; when it is unset or the binary is missing, that is `SURFACE_UNAVAILABLE`, never a fabricated success.

2. **Request adaptation — `argsAdapter: "positionalString"`.** The single positional argument is `args.value` when present (a string), otherwise `null`. A request for an act declaring `positionalString` that carries ANY key other than `value` → `BAD_REQUEST`. This is a faithful model of `cmd_act(what, arg)`, not a lossy one.

3. **Response adaptation — implement the §6.3 table exactly:**

| `cmd_act` result | Bus response |
| --- | --- |
| `{"ok": true, "exit": 0, "detail": "..."}` | `{ ok: true, data: { exit: 0, detail } }` |
| `{"ok": false, "exit": n, "detail": "..."}` | `{ ok: false, error: { code: "ENGINE_ERROR", message: <detail, ≤400 chars>, retryable: false, details: { exit: n } } }` |
| `{"ok": false, "error": "unknown action: x", "available": [...]}` | `{ ok: false, error: { code: "UNKNOWN_ACTION", message: "unknown action", retryable: false } }` — **`available[]` is DROPPED** unless the credential is `full` scope, where it moves to `error.details.available` |
| process spawn failed / agent not running | `{ ok: false, error: { code: "SURFACE_UNAVAILABLE", message: "…", retryable: true, retryAfterMs: 2000 } }` |

`detail` is already truncated to 400 chars on the Python side, matching `busError.message` — do not truncate again.

4. **Allowlist.** A browser-originated invocation may reach a desktop act only when the desktop manifest serves it AND the browser's `invokes[]` permits it. Never spawn an arbitrary string as a process argument: validate the action name against the §2.1 grammar before it goes anywhere near a spawn, pass arguments as an argv array (never a shell string), and never interpolate `args.value` into a shell command.

5. **Timeouts.** `deadlineMs` clamped to `[1000, 60000]`; the child process is killed at the deadline and the response is `TIMEOUT` (504). A spawn that never started is `SURFACE_UNAVAILABLE` (503), not `TIMEOUT` — the two are distinct per §6.2/§7.1.

6. **Audit.** One record per invocation in the shared shape (§9.1/§9.2), same columns slice 1 added, with `surface: "desktop"` as the target. Best-effort, never blocking. No token, secret, signature or privileged `args` value in the record.

## Honest degradation (normative, §7.2)

With the host agent down, an extension caller MUST see a typed error — `SURFACE_UNAVAILABLE` with `retryable: true`. It must never see `ok: true` with an empty, zeroed or synthesised `data`. `{ ok: true, data: null }` is a protocol violation for any reason. If you cannot distinguish "empty result" from "engine down", return `ENGINE_DOWN`.

## Do not

- Do not modify anything under `background/`, `content/` or any hub page.
- Do not add a dynamic `import()` to the service worker.
- Do not open a new port or a new listener. The lane is a child process (or existing socket), invoked from the gateway that already runs on :3847.
- Do not change the omarchy-toolbelt repo; if you believe a host-side change is required, say exactly what and why in the PR body instead of making it.

## Verification — paste the output in the PR body

Add `tests/bus-desktop-lane.test.mjs` that **imports and executes** the adapter with a stubbed spawn (a regex-over-source test fails `tests/regression/static-only-test-ratchet.test.js`). Cover every row of the §6.3 response table, plus: `args` with a key other than `value` → `BAD_REQUEST`; `available[]` stripped for a non-`full` credential and present under `full`; agent-not-running → `SURFACE_UNAVAILABLE` (not `TIMEOUT`); deadline exceeded after spawn → `TIMEOUT`; an action name failing the §2.1 grammar never reaches spawn; one audit record written per invocation in both the success and failure paths.

```
node --test --test-force-exit tests/bus-desktop-lane.test.mjs tests/bus-envelope-v1.test.mjs tests/gateway-server-hardening.test.mjs tests/gateway-dual-auth.test.js
npm run preflight
npm run security
```

## Repository constraint — v2 surface freeze

This repository is under the **v2 surface freeze**. Do not add a new `*-hub/` directory or standalone hub page, a new `background/modules/` engine that polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a `sidepanel/tools-catalog.json` entry with no counterpart in `omarchy-toolbelt/catalog/tools.json`. CI enforces this (`tests/regression/v2-surface-freeze-ratchet.test.js`) and your PR will be red. Prefer folding your change into an existing surface. Do **not** add a `// ratchet-ok:` comment to get around the gate — that hatch is for reviewed exceptions only, and using it without review gets the PR closed.
