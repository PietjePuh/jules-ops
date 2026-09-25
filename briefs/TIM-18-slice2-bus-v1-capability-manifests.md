Repo: PietjePuh/Toolbelt. Branch `bus/v1-capability-manifests`, cut from latest `main`. Create ONE branch and ONE pull request against `main`.

Do not ask any questions. Every decision you need is below. If something is genuinely undecidable, pick the option stated as "default" and say so in the PR description.

## SURFACE FREEZE (active, this repo)

The v2 plan is a subtraction plan, so new surface is not dispatched at all: no new `*-hub/` directory or standalone hub page, no new `background/modules/` engine polling an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, no `sidepanel/tools-catalog.json` entry without a host-catalog counterpart. Work that removes a duplicate, merges a surface, or moves an engine host-side ranks above security and feature work of equal size — it is the only class that makes the end-of-plan merge smaller.

You may NOT self-issue a `// ratchet-ok: <reason>` or `"ratchetOk"` escape hatch under any circumstances. If you believe you need one, stop and explain why in the PR description instead of adding it.

## Context

The bus protocol spec (`docs/TOOLBELT-BUS-PROTOCOL.md` + `docs/toolbelt-bus.schema.json`) lives on branch `v2-surface-freeze-ratchet` (commit `b736ea29`), which is NOT merged to `main` yet. Do not look for the spec file on main, do not merge or cherry-pick that branch into your PR — the sections you need are inlined below.

Slice 1 already landed (merged PR #4117): `POST /api/v1/bus` exists and routes through `isExtensionAction()`, `invokeBus()` is the envelope-native entry point, typed error objects work, `SURFACE_UNAVAILABLE`/`TIMEOUT`/`QUEUE_SATURATED` are split. Your job is spec §1.3 delta 4, and only that.

## The change

Replace `isExtensionAction()` as the ROUTING DECISION on the `/api/v1/bus` path with a capability-manifest lookup ("which surface's manifest `serves` this action"), per spec §1.3 delta 4 (originally `server.js:1255`):

1. **Gateway-side manifest store** (new module under `gateway/`, e.g. `gateway/capability-manifests.js`; NOT under `background/`):
   - Holds the authoritative copy of each surface's manifest from its last successful fetch (spec §3.2: the gateway evaluates `invokes[]` against ITS copy, never against the request).
   - `browser` manifest is fetched over the existing long-poll lane by sending `svc.capabilities` through `invokeBus()`.
   - Refresh: past `manifestTtlMs` (default 300 000) the gateway re-fetches.
   - **Stale-manifest rule (spec §3.2, normative):** if the re-fetch fails, the stale manifest STAYS IN FORCE and every routed call additionally audits `reason: "stale_manifest"`. The gateway MUST NOT fall back to "allow everything" (privilege escalation) or "deny everything" (manifest hiccup becomes a total outage).
   - **Bootstrap seed (default, spec §1.3 delta 4 wording):** until the first successful fetch — and as the permanent fallback content — `browser.serves` is seeded from today's `isExtensionAction()` regex applied over the `MCP_HANDLERS` types ∪ `SAFE_GATEWAY_ACTION_TYPES` (spec §3.2: NOT all 304 registry actions; the manifest is an opt-in export surface and widening it is a reviewed act). A fresher fetched copy always wins over the seed.
2. **Routing decision** in the `/api/v1/bus` handler: resolve the action via the existing alias/envelope path, then look it up in the serving surface's manifest. Not found → `UNKNOWN_ACTION`. `isExtensionAction()` MAY remain in the codebase as the seed content generator (per §1.3), but it must no longer be the routing decision itself.
3. **`svc.*` trio served by the browser surface** (spec §3.1 — every surface MUST serve these): in `background/modules/gateway-rpc.js` answer
   - `svc.ping` → `{ ok: true, data: { surface: "browser", ts } }`
   - `svc.versions` → `{ ok: true, data: { supportedVersions: [1], build } }`
   - `svc.capabilities` → `{ ok: true, data: <the browser capabilityManifest> }`
   These are answered by the SW's poll-loop dispatcher directly. Fold this into the EXISTING `gateway-rpc.js` — do not create any new file under `background/modules/`.
4. **Manifest entry shape** per `#/$defs/capabilityManifest` in `docs/toolbelt-bus.schema.json` on branch `v2-surface-freeze-ratchet`: `serves[]` entries carry at minimum the action name, `tier`, and aliases; `generatedAt` required; `manifestTtlMs` optional. Include `argsSchema` where trivially derivable, omit where not — do not fabricate schemas.
5. **Tier resolution** for the seed manifest (spec §5.1 sources of truth): `tier: "privileged"` iff the name is in `PRIVILEGED_ACTIONS` (floor baseline `tests/baselines/privileged-actions-floor-baseline.json`) or the registry action was registered with `audit: true`; `tier: "offensive"` for the `sec.hex.*` / `sec.kali.*` / `web.*Scan` / `sec.cape.*` families; everything else `open`.
6. **Aliases** in the seed manifest: mechanical Rule 1 only (spec §2.3) — lowercase first `_`-token, nine-namespace table for the token, lowerCamel the remainder (e.g. `WEB_CORS_SCAN` → `web.corsScan`, `DOCKER_HEALTH_STATUS` → `svc.docker.healthStatus`). PR #4123 (the full `docs/bus-action-aliases.json` generator) is NOT your dependency: do not wait for it, do not hand-build the Rule-2 camelCase table, do not check in an alias map file.

## Hard constraints (spec §5.3 — verbatim prohibitions)

- **Do NOT collapse the manifest check into `isMcpCallable()`.** They are two independent gates and both stay fail-closed: the manifest is the gateway's routing decision, `isMcpCallable()` in the SW remains the enforcing defence-in-depth check at the serving surface, untouched.
- **Do NOT generalise the url-less in-SW sender** (`{}` sender from `dispatchSafeGateway`) beyond `SAFE_GATEWAY_ACTION_TYPES`. That narrowing is preserved exactly. The `svc.*` trio is added to the safe set — they are open-tier liveness/capability calls by definition.
- Evaluation order stays as implemented (spec §5.4: IP allowlist → rate limit → auth → version → schema → action resolution → surface binding → tier/signature → `invokes[]` grant → route). Manifest lookup slots in at the action-resolution step. Every denial keeps producing `outcome: denied` audit records.
- Do NOT change HMAC/signature semantics. The per-action-mandatory signing upgrade (spec §4.3) is a later slice; keep the current global `REQUIRE_REQUEST_SIGNATURE` behaviour exactly.
- No dynamic `import()` anywhere in the service worker. No new bare `chrome.runtime.onMessage.addListener` in `background/`.
- Tests must import and execute the module under test — no source-regex assertions (static-only ratchet).
- Do not touch `catalog/`, `sidepanel/tools-catalog.json`, or any `*-hub/` page.

## Verification (run all, quote the output in the PR body)

```
node --test --test-force-exit tests/bus-envelope-v1.test.mjs tests/extension-rpc.test.mjs \
  tests/extension-rpc.test.js tests/gateway-server-hardening.test.mjs tests/gateway-dual-auth.test.js \
  tests/gateway-signature-gate.test.js tests/gateway-pairing.test.js tests/mcp-end-to-end.test.mjs
```
plus a new test file for: manifest-routing decision (served action routes, unserved → `UNKNOWN_ACTION`), stale-manifest stay-in-force + `stale_manifest` audit reason, `svc.ping`/`svc.versions`/`svc.capabilities` answered by the browser surface, and the seed falling back to the regex content when no fetch has succeeded.

```
npm run security
```
Pre-existing INFO/WARN noise is acceptable if you did not introduce it; state which findings are yours, if any.

```
npm run preflight
```
On a fresh `main` this is expected GREEN (the two reachability orphans were fixed by merged PR #4112). If you see exactly the `backup-manager.js` / `pentest-policy.js` orphan failures, your base predates #4112 — rebase onto `main`, do not fix them in your PR.

Open the PR titled `feat(bus): capability-manifest routing (TIM-18 slice 2)` with the test output and a one-paragraph statement of what changed per file.
