Repo: PietjePuh/Toolbelt. Base branch: main. Work on a new branch `bus/v1-mirror-news-consumers` and open ONE pull request. Do NOT push to main.

PREREQUISITES, both must be on main before this starts:
- TIM-18 slice 3 (`bus/v1-desktop-lane`) — the gateway can invoke a desktop act.
- omarchy-toolbelt slice 4 (`bus/v1-mirror-news-actions`) — the mirror snapshot and the news feed are reachable as acts.

If either is missing, stop and say so. Do not re-implement them.

You must NOT ask any questions. Every decision has been made below.

GOAL: move the two extension consumers off their direct loopback ports and onto the bus, so the host can stop binding `:3877` and `:8096`. This is port consolidation pass 1 (6 loopback ports → 3 externally, 1 internally).

## The changes

1. **`background/modules/toolbelt-mirror.js`** currently fetches `http://127.0.0.1:3877/snapshot` (`MIRROR_URL`, line 14). Repoint it at the bus: `POST http://127.0.0.1:3847/api/v1/bus` with a v1 `busRequest` (`v: 1`, `requestId: crypto.randomUUID()`, `action: 'svc.mirror.snapshot'`, `surface: 'browser'`, `ts: Date.now()`), Bearer token from `chrome.storage.local.toolbeltGatewayApiKey` — the credential that already exists (§6.4, no new credential distribution).

2. **`background/modules/news-bridge.js`** — same treatment for `NEWS_ENGINE_URL` (`http://127.0.0.1:8096`, line 28) and every call site that uses it. Use the act names omarchy-toolbelt's slice-4 PR actually shipped; read them from that PR rather than guessing.

3. **Honest degradation (§7.2, normative).** With the host down, the caller gets a typed error and the UI says so. It must NEVER render a fabricated empty result: no empty snapshot, no empty feed presented as a successful fetch. A `SURFACE_UNAVAILABLE` / `ENGINE_DOWN` response is surfaced as an error state in whatever renders it (bar Config tab, news feed). Check `background/modules/rss-feed-cache.js` too — its current "down/timeout/bad-shape all optional" handling must not silently swallow a typed bus error into an empty list.

4. **Manifest.** Removing `http://127.0.0.1:3877/*`, `http://127.0.0.1:8096/*` and `http://localhost:8096/*` from `manifest.json` `host_permissions` changes a snapshot frozen by `tests/regression/manifest-permission-freeze.test.js`. Update that snapshot in the SAME PR, with the justification in the PR body: these are narrowings, not widenings — the gateway origin `:3847` is already permitted. Do not remove a permission you have not actually stopped using.

5. **Service worker constraint.** No dynamic `import()` anywhere in the service worker — MV3 rejects it at registration time and this has broken the extension before. Static imports only.

## Do not

- Do not change the host repo in this PR.
- Do not remove the host listeners — a separate omarchy-toolbelt PR does that, after this one merges.
- Do not add a bare `chrome.runtime.onMessage.addListener` in `background/`; the bare-listener and sender-blind ratchets will fail the PR. Use `registerAction` + one import line in `background/modules/registered-actions.js`.
- Do not widen `host_permissions` or add an optional permission.

## Verification — paste the output in the PR body

Add/extend tests that **import and execute** the two bridge modules with a stubbed `fetch` (a regex-over-source test fails `tests/regression/static-only-test-ratchet.test.js`). Cover: a successful bus round trip returns the same shape the old direct fetch returned; a `SURFACE_UNAVAILABLE` response surfaces as a typed error and NOT as an empty snapshot/feed; a network failure to the gateway is an error state, not a silent empty; the Authorization header carries the stored gateway key and never appears in a log line.

```
node --test --test-force-exit tests/toolbelt-mirror*.test.* tests/news-bridge*.test.* tests/rss-feed-cache*.test.* tests/regression/manifest-permission-freeze.test.js tests/regression/bare-listener-ratchet.test.js
npm run preflight
npm run security
```

Also update `docs/` with the resulting port map: which loopback ports the extension still talks to after this PR, and which are gone.

## Repository constraint — v2 surface freeze

This repository is under the **v2 surface freeze**. Do not add a new `*-hub/` directory or standalone hub page, a new `background/modules/` engine that polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a `sidepanel/tools-catalog.json` entry with no counterpart in `omarchy-toolbelt/catalog/tools.json`. CI enforces this (`tests/regression/v2-surface-freeze-ratchet.test.js`) and your PR will be red. Prefer folding your change into an existing surface. Do **not** add a `// ratchet-ok:` comment to get around the gate — that hatch is for reviewed exceptions only, and using it without review gets the PR closed.
