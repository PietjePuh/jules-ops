# TIM-32 — Toolbelt CI group D: writing-companion test harness captures the wrong onMessage listener

Surface: Toolbelt. Rank: 2 (CI-red unblock — 24 assertions, the largest single block).
File-disjoint from live sessions `14586316274894910497` (TIM-25 stale tests) and
`3590568032759800948` (TIM-16 freeze ratchet): this brief touches exactly one
file, `tests/writing-companion.test.js`, which neither of those sessions edits.

Repo: `PietjePuh/Toolbelt`. Base branch: `main`. Work on a new branch and open
ONE pull request against `main`. Do NOT push to `main`. Do NOT merge.

You must NOT ask any questions. Every decision is made below.

## Diagnosis — already proven locally on `main` @ `b0daf9d1`. Do not re-derive it.

`tests/writing-companion.test.js` fails 24 of 27 assertions. Every failure is the
same one cause, and it is **test-harness drift, not a product break**.

The harness stubs `chrome.runtime.onMessage.addListener` and keeps only the
FIRST listener it is handed:

```js
addListener: (fn) => { if (!capturedListener) capturedListener = fn; },
```

But importing `background/modules/writing-companion.js` registers **two**
listeners, in this order:

1. `background/modules/offscreen-llm-manager.js` line 256 — the offscreen→SW
   progress relay, registered at module-evaluation time. It is pulled in
   transitively: `writing-companion.js` → `ai-gateway.js` (line 17) →
   `offscreen-llm-manager.js`. ESM evaluates dependencies before the importing
   module's own body, so this one registers first.
2. `background/modules/writing-companion.js` line 393 — the real handler.

So `capturedListener` is the offscreen progress relay. It returns `false` for
anything without `message.target === 'sw'`, which is why every `send()` resolves
to `{ ok: false, error: 'listener did not return true' }` and every
`r.data.enabled` read then throws `Cannot read properties of undefined`.

Verified by probe (fake `chrome`, import `writing-companion.js`, log every
registered listener):

```
listeners registered: 2
--- [0] --- (message, _sender, sendResponse) => {
    if (!message || message.target !== 'sw') return false;
    if (message.action === 'localLlmProgress') { writePro…
--- [1] --- (message, sender, sendResponse) => {
  if (message.type === 'WRITING_COMPANION_TRANSFORM') { …
```

### The shipped extension is NOT broken. State this in the PR body.

Three independent confirmations — do not "fix" the background module:

- Chrome dispatches a `runtime.sendMessage` to **every** registered
  `onMessage` listener. One listener returning `false` does not stop another
  from answering. Only the harness's first-listener-wins stub does that.
- `background/service-worker.js` line 353 imports
  `./modules/writing-companion.js`, so the handler is registered in the real SW.
- `background/service-worker.js` line 1011 has
  `request.type.startsWith('WRITING_COMPANION_')` in the central router's
  module-listener bail list, so the central switch deliberately does **not**
  swallow these types. The namespaced-type change named as the prime suspect in
  the ticket is not the cause.

## The change — `tests/writing-companion.test.js` only

Make the stub behave like Chrome: collect every listener and fan the message out
to all of them.

1. Next to `let capturedListener = null;` add `const listeners = [];`.
2. Change the stub to push as well as capture:
   `addListener: (fn) => { listeners.push(fn); if (!capturedListener) capturedListener = fn; },`
3. Add a `dispatch()` helper above `send()` that mirrors Chrome's fan-out — call
   every listener, and report async-response intent if ANY of them returned
   `true`:

   ```js
   function dispatch(message, sender = {}, sendResponse = () => {}) {
     let async = false;
     for (const fn of listeners) {
       if (fn(message, sender, sendResponse) === true) async = true;
     }
     return async ? true : undefined;
   }
   ```

4. Have `send()` call `dispatch(message, {}, resolve)` instead of
   `capturedListener(message, {}, resolve)`. Keep the
   `if (ret !== true) resolve({ ok: false, error: 'listener did not return true' })`
   line exactly as it is — it is the harness's own failure mode and must stay.
5. Replace every remaining direct `capturedListener(` call site in the file with
   `dispatch(` — including the ones that pass a real `sender` for the rate-limit
   tests. Same argument order, no other change.

Do not change any assertion, any expected value, any test name, or any
`resetSettings` / `installFetch` helper. Do not delete or skip a test. Do not
touch `background/modules/writing-companion.js`,
`background/modules/offscreen-llm-manager.js`,
`background/modules/ai-gateway.js`, or `background/service-worker.js`.

### One allowed strengthening

The test `writing-companion registers an onMessage listener during import`
currently passes vacuously — it asserts only that *some* listener exists, which
is exactly how this regression hid. Keep the test and its name, and add one
assertion to it proving the writing-companion handler specifically is present:

```js
assert.equal(dispatch({ type: 'WRITING_COMPANION_GET_SETTINGS' }), true,
  'a registered listener must claim WRITING_COMPANION_ messages');
```

That is the only assertion you may add. Leave `capturedListener` declared and
assigned so the existing first test still reads naturally.

## Scope — read this twice

`main` is red for several independent reasons that are being fixed by other
PRs in parallel. Fix ONLY group D. If another test file is red when you run the
suite, leave it red and say so in the PR body. Do not touch
`tests/regression/*`, do not delete any test file, do not edit any baseline or
allowlist JSON under `tests/baselines/`.

**Never** silence a ratchet by raising its baseline or adding an allowlist entry
to make it pass. If you believe an entry is legitimate, say so in the PR body
with a reason and let the reviewer decide. Adding a `// ratchet-ok:` comment is
forbidden in this PR.

## Repository constraint — v2 surface freeze

This repository is under the **v2 surface freeze**. Do not add a new `*-hub/` directory or standalone hub page, a new `background/modules/` engine that polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a `sidepanel/tools-catalog.json` entry with no counterpart in `omarchy-toolbelt/catalog/tools.json`. CI enforces this (`tests/regression/v2-surface-freeze-ratchet.test.js`) and your PR will be red. Prefer folding your change into an existing surface. Do **not** add a `// ratchet-ok:` comment to get around the gate — that hatch is for reviewed exceptions only, and using it without review gets the PR closed.

This PR adds no surface of any kind — it edits one existing test file.

## Verification — run these and paste the output into the PR description

Setup (the `build:popup` step is REQUIRED; skipping it produces a false ENOENT
failure in `tests/regression/popup-favicon-csp.test.js`, because
`src/popup/popup.js` is a gitignored build artifact of `src/popup/popup.ts` —
that test is NOT orphaned, do not delete it):

```
pnpm install --frozen-lockfile
pnpm run build:popup
node scripts/sync-tools-catalog.cjs
```

Before/after counts for the one file, both required in the PR body:

```
node --test tests/writing-companion.test.js
```

Expected before: `tests 27 / pass 3 / fail 24`.
Expected after: `tests 27 / pass 27 / fail 0`.
(27 not 24: the two currently-passing tests stay passing, and the one extra
assertion above lands inside an existing test, so the total does not change.)

Then the whole shard, to prove you did not move anything else:

```
node scripts/test-shards.cjs --run 3 4
```

Paste the shard's before and after summary lines. Any failure in shard 3 that is
not in `tests/writing-companion.test.js` must be unchanged between the two runs —
list them by name in the PR body and leave them alone.

Finally:

```
pnpm run lint
```

## PR body must contain

- The sentence: **"Test-harness drift, not a user-facing break — the shipped
  extension still works, because Chrome dispatches to every registered
  onMessage listener."**
- The three confirmations from the "shipped extension is NOT broken" section
  above, with file and line references.
- The before/after counts for `tests/writing-companion.test.js` and for shard 3.
- The named list of shard-3 failures you left alone.

Label the PR `no-auto-merge`. Open it as ready for review, not as a draft.
Do not merge it — a human merges every PR in this repo.

If anything in this brief looks ambiguous, take the narrowest reading that still
makes `node --test tests/writing-companion.test.js` report 27/27, and say which
reading you took in the PR body. Do not ask questions.
