Repo: PietjePuh/Toolbelt. Base branch: main. Work on a new branch `bus/v1-envelope-extension-lane` and open ONE pull request. Do NOT push to main.

You must NOT ask any questions. Every decision has been made below. If something is genuinely ambiguous, pick the option that changes the least and say so in the PR body.

GOAL: put the v1 bus envelope on the extension RPC lane that already exists, and add the single bus entry point. This is routing + envelope work on a LIVE channel. Do not build a new broker, a new process, a new port, or a new transport.

## Read first — the spec is authoritative

`docs/TOOLBELT-BUS-PROTOCOL.md` sections 1.1, 1.2, 1.3, 6.1, 6.2, 7.1, 7.2, 9.1, 9.2, and the JSON Schema `docs/toolbelt-bus.schema.json` (`#/$defs/busRequest`, `#/$defs/busResponse`, `#/$defs/busError`). Where this brief and the spec disagree, the spec wins.

Section 1.3 lists exactly four deltas. This PR lands three of them (1, 2, 3). Delta 4 (capability manifests replacing `isExtensionAction()` as the routing decision) is a SEPARATE PR — do not start it here, and leave `isExtensionAction()` in place as the routing decision.

## The changes

### 1. `gateway/extension-rpc.js` — push the full envelope (§1.3 delta 1)

Today `invokeExtension(type, payload, { timeoutMs })` does `requestQueue.push({ id, type, payload })` (around line 119). Change it so the queued job is the caller's full v1 request envelope (`v`, `requestId`, `action`, `args`, `surface`, `ts`, `deadlineMs`) WITH `id` / `type` / `payload` still present as deprecated mirrors (`id` === `requestId`, `type` === `action`, `payload` === `args`).

Add an envelope-native entry point `invokeBus(request, { timeoutMs })` that takes the envelope as its argument and returns the full v1 response envelope. Keep `invokeExtension(type, payload, opts)` exported and working unchanged for every existing caller — implement it as a thin wrapper that synthesises an envelope (`v: 1`, `requestId: randomUUID()`, `action: type`, `args: payload || {}`, `surface: 'agent'`, `ts: Date.now()`) and maps the response back to today's `{ ok, data }` / `{ ok: false, error: <string> }` shape.

This is additive. `background/modules/gateway-rpc.js` must need NO change — its `{ type: job.type, ...job.payload }` dispatch and its `isMcpCallable(job.type)` gate keep firing on the mirrors. **Do not modify any file under `background/` in this PR.** No flag day.

### 2. `gateway/extension-rpc.js` — typed error objects in `handleRespond` (§1.3 delta 2)

`handleRespond` currently does `typeof body.error === 'string' ? body.error : 'extension reported error'` (around lines 188-193), which silently discards `code` and `retryable` from a v1 error object. This is the one non-backwards-compatible change and it MUST land:

- Accept `body.error` as an object and validate it against `#/$defs/busError` (`code` from the §7.1 enum, `message` ≤ 400 chars, `retryable` boolean, optional `retryAfterMs`, optional `details`).
- Keep the string branch as a legacy coercion to `{ code: 'ENGINE_ERROR', message: <string>, retryable: false }`.
- An object that fails validation → `{ code: 'ENGINE_ERROR', message: 'malformed error from surface', retryable: false }`.
- Per §1.2: `ok: true` with no `data`, or `ok: false` with no `error`, or a non-boolean `ok`, is a protocol violation — the gateway replaces the whole response with `ENGINE_ERROR` (reason `malformed_response`). Do not guess, do not synthesise a `data`.

### 3. `gateway/extension-rpc.js` — split `SURFACE_UNAVAILABLE` from `TIMEOUT` (§6.2, §7.1)

Today both collapse into one timeout message. Track whether the job was ever dequeued by a poller:

- Deadline elapsed and the job was NEVER dequeued → `SURFACE_UNAVAILABLE` (HTTP 503, `retryable: true`, `retryAfterMs: 2000`) — no poller is attached.
- Deadline elapsed after a poller took the job → `TIMEOUT` (HTTP 504, `retryable: true`).
- Queue at `QUEUE_HARD_LIMIT` → `QUEUE_SATURATED` (HTTP 503, `retryable: true`).

### 4. `gateway/server.js` — `POST /api/v1/bus` (§1.3 delta 3, §6.1)

There are TWO regexes blocking dotted action names, not one. The route matcher `/^\/api\/(\w+)$/` (around line 1199) excludes `.` and 404s before `isExtensionAction()` is ever reached. Do not widen it.

Add a new route `POST /api/v1/bus` matched BEFORE that matcher. The action lives in the request body, not the path, so dotted names work without touching the frozen `/api/<action>` routes. Those existing routes keep their current shapes and no new action becomes reachable through them.

The new route:

- Runs through the SAME middleware chain as today's `/api/*`: auth (`isAuthorized`), HMAC signature gate, replay/nonce window, rate limiting, audit. Do not add a bypass and do not reorder the gates (§5.4 ordering).
- A `paired`-scope token may still call ONLY `SAFE_GATEWAY_ACTION_TYPES` — enforce it on the resolved action name, server-side, exactly as the existing route does. A dotted name that resolves to a non-safe action under a paired token → `FORBIDDEN` (403).
- Validates the request envelope against `#/$defs/busRequest`: missing/malformed `v`, `requestId`, `action`, `surface` or `ts` → `BAD_REQUEST` (400); unknown major → `UNSUPPORTED_VERSION` (400) with `details.supported: [1]`; `args` not an object → `BAD_REQUEST`; `deadlineMs` clamped silently to `[1000, 60000]` with the effective value returned in `data._deadlineMs` on success.
- Duplicate `requestId` inside the active nonce window → `REPLAY` (409). The first response is NOT replayed.
- HTTP status mirrors the bus code per the §7.1 table; the body is authoritative and is always a full `busResponse`.
- Routes to the extension lane via `invokeBus()` when `isExtensionAction(action)` is true (the regex stays as the routing decision for now — manifests are the next PR). Anything else → `UNKNOWN_ACTION` (404). Do NOT send unknown actions to `runNativeBridgeUtility()`.
- The gateway never originates an envelope and never synthesises a `data` payload (§3.1, §7.2).

### 5. Audit — one record per invocation (§9.1, §9.2)

`private_api_audit_logs` (`gateway/db.js`) keeps its 11 existing columns populated exactly as today. Add `v`, `request_id`, `surface`, `caller` and `tier` as additive nullable columns with a guarded `ALTER TABLE ... ADD COLUMN` migration that is safe to run against an existing database and safe to run twice. Populate them for `/api/v1/bus` calls. Auditing is best-effort and MUST NOT fail or block a dispatch.

An audit write MUST NOT contain the Bearer token, the HMAC secret, a signature, a full sender URL, or an `args` value from a privileged action.

## Do not

- Do not modify anything under `background/`, `content/`, or any hub page.
- Do not add a dynamic `import()` anywhere in the service worker — MV3 rejects it at registration time.
- Do not change `isExtensionAction()`'s role as the routing decision (next PR).
- Do not touch `mcp/`, `scripts/cli-agent-bridge.mjs`, `bin/toolbelt_mirror.py` consumers, or any port binding. No port changes in this PR.
- Do not fix unrelated failing tests on main. Main is currently red from five independent pre-existing root causes with a fix already in flight in another PR. Touching them causes a merge conflict and gets this PR flagged as a duplicate.

## Verification — run these and paste the output in the PR body

Add `tests/bus-envelope-v1.test.mjs`. It must **import and execute** the modules under test (`await import('../gateway/extension-rpc.js')` with a stubbed transport) — a test whose assertions are regexes over the module's source text fails the static-only test ratchet (`tests/regression/static-only-test-ratchet.test.js`) and will be rejected. Cover, at minimum:

1. A queued job carries the full envelope AND the `id`/`type`/`payload` mirrors.
2. A legacy string `error` in a respond body coerces to `{ code: 'ENGINE_ERROR', retryable: false }`.
3. A v1 error object survives with its `code` and `retryable` intact.
4. `ok: true` with no `data` is rewritten to `ENGINE_ERROR`, not passed through.
5. Deadline with no poller attached → `SURFACE_UNAVAILABLE`; deadline after dequeue → `TIMEOUT`.
6. `POST /api/v1/bus` with a dotted action reaches the extension lane and returns a full `busResponse`.
7. A malformed envelope (missing `v`, missing `surface`, `args` an array) → `BAD_REQUEST`.

Then run:

```
node --test --test-force-exit tests/bus-envelope-v1.test.mjs tests/extension-rpc.test.mjs tests/extension-rpc.test.js tests/gateway-server-hardening.test.mjs tests/gateway-dual-auth.test.js tests/gateway-signature-gate.test.js tests/gateway-pairing.test.js tests/mcp-end-to-end.test.mjs
npm run preflight
npm run security
```

All of those must be green. `npm run preflight` runs the ratchets locally; if it fails with module-resolution errors (`Cannot find module 'eslint'`, `@scure/*`, …) run `npm run fix:node-modules` first rather than concluding the environment is broken.

## Repository constraint — v2 surface freeze

This repository is under the **v2 surface freeze**. Do not add a new `*-hub/` directory or standalone hub page, a new `background/modules/` engine that polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a `sidepanel/tools-catalog.json` entry with no counterpart in `omarchy-toolbelt/catalog/tools.json`. CI enforces this (`tests/regression/v2-surface-freeze-ratchet.test.js`) and your PR will be red. Prefer folding your change into an existing surface. Do **not** add a `// ratchet-ok:` comment to get around the gate — that hatch is for reviewed exceptions only, and using it without review gets the PR closed.

## PR body must contain

- Which of the four §1.3 deltas this PR lands (1, 2, 3) and which it deliberately leaves (4).
- The full output of the test commands above.
- One sentence per changed file saying what changed and why.
