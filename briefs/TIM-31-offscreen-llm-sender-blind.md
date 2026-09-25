# TIM-31 — sender-blind onMessage listener in offscreen-llm-manager.js (CI-red group A)

Surface: Toolbelt. Rank: security + ratchet/gate work — three CI assertions, one root cause.
File-disjoint from live sessions `3590568032759800948` (tests/regression/v2-surface-freeze-ratchet.test.js),
`14586316274894910497` (tests/*.test.mjs, tests/error-tag-consistency.test.js, package.json)
and `1861008097792993223` (gateway/*).

Repo: `PietjePuh/Toolbelt`. Base branch: `main` (at `b0daf9d1`). Work on a new branch
`fix/offscreen-llm-progress-registry` and open ONE pull request against `main`.
Do NOT push to main. Do NOT merge. Label the PR `no-auto-merge`.

**You must NOT ask any questions. Every decision is made below.** If a fact below turns
out to be false in the tree, do the smallest correct thing and say so in the PR body.

## The defect

Commit `c21af3a7` added an own `chrome.runtime.onMessage` listener at the bottom of
`background/modules/offscreen-llm-manager.js` (around line 255):

```js
globalThis.chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || message.target !== 'sw') return false;
  if (message.action === 'localLlmProgress') { ... }
  if (message.action === 'localLlmProgressInit') { ... }
  return false;
});
```

The sender is destructured away. `message.target !== 'sw'` is a *routing* convention, not an
authorization check — a content script in any web page can call
`chrome.runtime.sendMessage({ target: 'sw', action: 'localLlmProgress', pct: 100, text: '...' })`
and write attacker-chosen values into the `localLlmLoadProgress` storage key that the sidepanel
and the AI-hub model picker read.

Three tests report this same root cause:

| test | assertion |
| --- | --- |
| `tests/regression/sender-blind-listener-ratchet.test.js` | `sender-blind ... listener(s) added in background/: offscreen-llm-manager.js` |
| `tests/regression/central-router-namespaced-types.test.js` | `not in MODULE_LISTENERS: ["offscreen-llm-manager.js"]` |
| `tests/regression/bare-listener-ratchet.test.js` | `bare ... addListener calls in background/ rose to 39 (baseline 38)` |

## The fix — migrate to the action registry. Two files.

The only intended sender is the offscreen document `offscreen/local-llm.js`, which is an
extension page (`chrome-extension://<our-id>/offscreen/local-llm.html`). The registry's central
gate is default-deny and already does exactly the right thing for it:
`isGatedSender()` in `background/modules/action-registry.js:121` returns `false` for any sender
whose `url` starts with `chrome.runtime.getURL('')`, so the offscreen doc passes and a content
script (whose `sender.url` is the http(s) host page) is rejected **before the handler runs**.

I have already verified the wiring — you do not need to re-derive it:

- `background/service-worker.js:6132` dispatches the switch `default:` case through
  `hasRegisteredAction(request.action || request.type)` → `runRegisteredAction(...)`.
  Nothing in the central listener bails on `request.target`, so a `{ target: 'sw', action: 'localLlmProgress' }`
  envelope reaches that default case unchanged.
- `background/modules/registered-actions.js:397` already imports `./actions/local-llm-chat.js`,
  which imports `../offscreen-llm-manager.js`. So this module is already in the SW import graph.

### 1. `background/modules/offscreen-llm-manager.js`

- Add `import { registerAction } from './action-registry.js';` at the top of the file
  (same directory — `./`, not `../`).
- **Delete the entire `if (typeof globalThis.chrome !== 'undefined' && globalThis.chrome?.runtime?.onMessage) { ... addListener ... }` block**, including its `// ── Offscreen → SW progress relay ──` comment banner. Do not leave a gated
  version of it behind — the point is that the file ends up with zero
  `chrome.runtime.onMessage.addListener` calls, which is what drops the bare-listener count
  back to 38 on its own.
- Replace it with two registrations that preserve the existing behaviour exactly:

  - `registerAction('localLlmProgress', ...)` — `await writeProgress({ model, pct, text, done: false })`
    with the same type coercions the listener did (`typeof message.pct === 'number' ? message.pct : 0`,
    `typeof message.text === 'string' ? message.text : ''`, `message.model || null`), then return
    `{ ok: true }`. Keep the existing `.catch()`/`console.warn` behaviour so a storage failure never
    rejects the dispatch.
  - `registerAction('localLlmProgressInit', ...)` — same "seed the idle marker but never clobber
    real progress" logic: read `PROGRESS_KEY` from `chrome.storage.local`, return early if it is
    already set, otherwise `writeProgress({ done: true, pct: 0, text: 'idle', model: null })`.
    Return `{ ok: true }`.
  - Do **not** pass `{ allowContentScript: true }` to either one. Default-deny is the fix.
  - Rewrite the comment banner to explain the new shape: offscreen documents cannot use
    `chrome.storage`, so the offscreen doc reports progress over `chrome.runtime` and this module
    owns the `localLlmLoadProgress` storage key — now through the gated registry rather than an
    own listener.

  A registry handler's **return value is the response**, so `sendResponse` disappears. Both
  handlers may be `async`.

### 2. `background/modules/registered-actions.js`

Add one explicit import line so registration does not depend on the transitive path through
`actions/local-llm-chat.js`:

```js
import './offscreen-llm-manager.js';
```

Place it with the other modules-root imports (the file keeps `./actions/*` and modules-root
imports interleaved with explanatory comments — follow the surrounding style and add a one-line
comment saying it self-registers `localLlmProgress` / `localLlmProgressInit`). ESM dedupes, so
the existing transitive import costs nothing.

### 3. `offscreen/local-llm.js` — leave the sends alone, but check them

The two sends at lines ~36 and ~304 already use `{ target: 'sw', action: 'localLlmProgress' }` /
`{ ... action: 'localLlmProgressInit' }`. That is already the registry envelope
(`request.action` is what the dispatcher keys off), so **no change should be needed**. Confirm
that by reading them. If you find a send that does not carry a top-level `action` string, fix
that send and say so in the PR body.

Also update the stale comment at `offscreen/local-llm.js:31` which says "listener in
background/modules/offscreen-llm-manager.js writes storage.local" — it is now a registered
action, not a listener.

**Do not touch** `chrome.runtime.sendMessage({ target: 'sw', action: 'localLlmOffscreenReady' })`
at line ~296. Nothing handles that action anywhere in the tree; it is a pre-existing no-op and
fixing it is out of scope for this PR. Mention it in the PR body as an observation.

## Explicitly forbidden

- **Do NOT raise `BASELINE` in `tests/regression/bare-listener-ratchet.test.js` from 38 to 39.**
  That turns CI green and ships the hole. The ratchet header says the set may only shrink. If you
  find yourself editing that number, your fix is wrong — the listener must be gone, not counted.
- Do NOT add `offscreen-llm-manager.js` to the grandfathered set in
  `tests/regression/sender-blind-listener-ratchet.test.js`.
- Do NOT add an entry to `MODULE_LISTENERS` in
  `tests/regression/central-router-namespaced-types.test.js`. With the own-listener deleted,
  that test stops applying to this module by itself.
- Do NOT edit any other test's baseline or allowlist to make something unrelated pass.
- `main` is red for several independent reasons. **Fix only this group.** Other sessions own the
  other groups; touching their files causes a merge conflict. In particular do not touch
  `package.json`, `tests/error-tag-consistency.test.js`, `tests/install-handler.test.mjs`,
  `gateway/*`, `tests/regression/v2-surface-freeze-ratchet.test.js`, or anything under
  `sidepanel/writing-companion*`.

If you conclude the registry path genuinely cannot work for an offscreen sender, fall back to
gating the existing listener with `isGatedSender(sender)` (the pattern is at
`background/modules/threat-shield.js:1025`) plus a `MODULE_LISTENERS` entry with a namespace and
a `service-worker.js` bypass. That clears two of the three tests — **say so explicitly in the PR
body**, and still do not bump the baseline.

## Verification — run these and paste the output in the PR body

Setup is not optional; several tests scan the BUILT bundle, and skipping the build produces a
false `ENOENT` failure in `tests/regression/popup-favicon-csp.test.js`. That test is **not**
orphaned — `src/popup/popup.js` is a gitignored build artifact of `src/popup/popup.ts`. Do not
delete it.

```bash
pnpm install --frozen-lockfile
pnpm run build:popup
node scripts/sync-tools-catalog.cjs
```

Then, on `main` first (before your change) and again on your branch:

```bash
node --test tests/regression/sender-blind-listener-ratchet.test.js
node --test tests/regression/central-router-namespaced-types.test.js
node --test tests/regression/bare-listener-ratchet.test.js
node --test tests/offscreen-llm-manager.test.js
```

All four must pass on your branch. Then run the full shard set to prove you did not break
anything else:

```bash
node scripts/test-shards.cjs --run 0 4
node scripts/test-shards.cjs --run 1 4
node scripts/test-shards.cjs --run 2 4
node scripts/test-shards.cjs --run 3 4
```

`main` is red for other reasons, so the shards will still report failures you did not cause.
Paste the before/after failure lists so it is obvious which ones your PR removed and that it
added none.

## Repository constraint — v2 surface freeze

This repository is under the **v2 surface freeze**. Do not add a new `*-hub/` directory or standalone hub page, a new `background/modules/` engine that polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a `sidepanel/tools-catalog.json` entry with no counterpart in `omarchy-toolbelt/catalog/tools.json`. CI enforces this (`tests/regression/v2-surface-freeze-ratchet.test.js`) and your PR will be red. Prefer folding your change into an existing surface. Do **not** add a `// ratchet-ok:` comment to get around the gate — that hatch is for reviewed exceptions only, and using it without review gets the PR closed.

## PR body must contain

- The bare-listener count before and after (expected: 39 → 38).
- The pass/fail line for each of the four tests above, before and after.
- One sentence on the runtime behaviour: offscreen load progress still reaches the sidepanel —
  the `localLlmLoadProgress` storage key is written by the same `writeProgress()` call, just
  reached through the gated registry dispatch instead of an ungated own listener.
- The `localLlmOffscreenReady` observation.
- A statement that no ratchet baseline or allowlist was modified.
