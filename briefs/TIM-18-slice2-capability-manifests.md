Repo: PietjePuh/Toolbelt. Base branch: main. Work on a new branch `bus/v1-capability-manifests` and open ONE pull request. Do NOT push to main.

PREREQUISITE: the branch `bus/v1-envelope-extension-lane` (TIM-18 slice 1: envelope on the extension lane + `POST /api/v1/bus`) must be merged to main before this starts. If `POST /api/v1/bus` does not exist in `gateway/server.js` on main, stop and say so in the session — do not re-implement it.

You must NOT ask any questions. Every decision has been made below.

GOAL: replace `isExtensionAction()` as the routing DECISION with a capability-manifest lookup. This is §1.3 delta 4 plus §3 of the spec.

## Read first

`docs/TOOLBELT-BUS-PROTOCOL.md` §2.1 (grammar), §2.2 (the nine namespaces), §3.1, §3.2, §5.1-5.4, §7.1. Schema: `docs/toolbelt-bus.schema.json` `#/$defs/capabilityManifest`. The spec wins over this brief.

## The changes

1. **Manifest store in the gateway.** The gateway holds, per surface, the last successfully fetched `capabilityManifest`. Routing asks "which surface's manifest `serves` this action" instead of "does the name match `/^[A-Z][A-Z0-9_]{1,63}$/`". An action in no manifest → `UNKNOWN_ACTION` (404). An action the CALLING surface does not list in its own `invokes[]` → `FORBIDDEN` (403); the gateway evaluates against ITS authoritative copy, never against a manifest supplied in the request.

2. **Bootstrap content for v1** (§3.2): `browser.serves` = the 38 `MCP_HANDLERS` types plus the `SAFE_GATEWAY_ACTION_TYPES` set — NOT all 304 registry actions. The manifest is an opt-in export surface and widening it is a reviewed act. `agent.serves` = `[]`. `isExtensionAction()`'s regex MAY remain as the mechanical source of the browser manifest's bootstrap content; it just stops being the routing decision.

3. **The three reserved meta-actions** (§3.1): every surface serves `svc.ping` (`{ surface, ts }`), `svc.versions` (`{ supportedVersions: [1], build }`) and `svc.capabilities` (the manifest itself). Add the browser side in the extension via the action registry (`registerAction` in `background/modules/actions/` + one import line in `background/modules/registered-actions.js`) — never a bare `chrome.runtime.onMessage.addListener`, the bare-listener ratchet will fail your PR.

4. **Manifest staleness** (§3.2, load-bearing): `manifestTtlMs` defaults to 300000. Past TTL the gateway re-fetches. If the re-fetch FAILS, the stale manifest STAYS IN FORCE and every routed call additionally audits `reason: stale_manifest`. The gateway MUST NOT fall back to "allow everything" (privilege escalation) or "deny everything" (a manifest hiccup becoming a total outage). An `engines[]` entry whose status could not be determined is `unknown`, never `up`.

## Do not

- Do NOT collapse the manifest check and the service worker's `isMcpCallable()` gate into one gate (spec §5.3). They are independent and both fail-closed; merging them removes a layer.
- Do NOT generalise the url-less in-service-worker sender that `dispatchSafeGateway` passes beyond `SAFE_GATEWAY_ACTION_TYPES` (spec §5.3).
- Do NOT add a dynamic `import()` to the service worker — MV3 rejects it at registration.
- Do NOT widen `/api/<action>`; those routes are frozen for v1.
- Do NOT generate `docs/bus-action-aliases.json` — deliverable 1.5 owns the alias map. Resolve only the names you need for bootstrap.

## Verification — paste the output in the PR body

Add `tests/bus-capability-manifest.test.mjs` that **imports and executes** the modules (a test whose assertions are regexes over module source text fails `tests/regression/static-only-test-ratchet.test.js`). Cover: an action in a manifest routes; an action in none → `UNKNOWN_ACTION`; a caller invoking outside its `invokes[]` → `FORBIDDEN`; a request-supplied manifest is ignored; an expired manifest whose re-fetch fails still routes AND audits `stale_manifest`; `svc.ping` / `svc.versions` / `svc.capabilities` answer on the browser surface.

```
node --test --test-force-exit tests/bus-capability-manifest.test.mjs tests/bus-envelope-v1.test.mjs tests/extension-rpc.test.mjs tests/gateway-server-hardening.test.mjs tests/action-registry.test.mjs tests/regression/bare-listener-ratchet.test.js tests/regression/sender-blind-listener-ratchet.test.js
npm run preflight
npm run security
```

## Repository constraint — v2 surface freeze

This repository is under the **v2 surface freeze**. Do not add a new `*-hub/` directory or standalone hub page, a new `background/modules/` engine that polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a `sidepanel/tools-catalog.json` entry with no counterpart in `omarchy-toolbelt/catalog/tools.json`. CI enforces this (`tests/regression/v2-surface-freeze-ratchet.test.js`) and your PR will be red. Prefer folding your change into an existing surface. Do **not** add a `// ratchet-ok:` comment to get around the gate — that hatch is for reviewed exceptions only, and using it without review gets the PR closed.
