# TIM-25 — finish the CI unbreak: retire tests for features deliberately removed in 74f702e3

Surface: Toolbelt. Rank: 2 (ratchet/gate work — unblocks the whole PR queue).
Supersedes PR #4097 (same intent, but #4097 is incomplete — see below).
File-disjoint from live session `5773481294591418578` ("Unbreak main: 5 root causes").

## Diagnosis (from CI run 36025835021 on main @ b0daf9d1)

Commit `74f702e3` — "Remove Pipelines + playbook checklist + fake ESP32 UI" —
deleted `background/modules/pipeline-executor.js` and `content/esp32-controller.js`
on purpose. Several tests still read those files off disk with `readFileSync`, so
they fail with `ERR_TEST_FAILURE` / ENOENT. These tests are genuinely stale: they
assert a feature that was intentionally removed. Retiring them is correct and is
NOT weakening the suite.

Separately `manifest.json` was bumped to 1.4.14 but `package.json` stayed 1.4.13,
which reds `Extension - Lint, Test & Package` before any test runs.

## What #4097 already gets right, and what it misses

#4097 (`fix/ci-orphaned-tests-version-sync`) does the version bump, deletes the
esp32/word-counter/subdomain test files, and removes the
`modules/pipeline-executor.js` line from `FILE_ALLOWLIST`. All correct.

It **misses** `tests/install-handler.test.mjs`, which still has
`initDefaultPipelines: seeds 4 default pipelines when storage empty` failing with
`'toolbelt_pipelines seeded'` — the Pipelines seeding code is gone, so the test can
never pass. That single omission keeps main red even if #4097 merges.

## The brief

Repo: `PietjePuh/Toolbelt`. Base branch: `main` (at `b0daf9d1`). Work on a new
branch and open ONE pull request. Do NOT push to main. Do NOT merge.

You must NOT ask any questions. Every decision is made below.

### 1. Version drift

`package.json` `"version"` → `1.4.14`, matching `manifest.json`. Nothing else.

### 2. Delete stale test files

Delete these five, but **verify each one first**: open it, find the `readFileSync`
/ path it resolves, and confirm that path does not exist on `main`. If a file
resolves to something that DOES still exist, do not delete it — report it in the
PR description instead.

- `tests/word-counter.test.mjs`
- `tests/esp32-controller.test.mjs`
- `tests/esp32-controller-response-shapes.test.mjs`
- `tests/esp32-dead-catch-false-ok.test.mjs`
- `tests/subdomain-takeover-candidate-shape.test.mjs`

### 3. `tests/error-tag-consistency.test.js`

Remove the single `'modules/pipeline-executor.js',` line from the `FILE_ALLOWLIST`
set. Failing assertion:
`FILE_ALLOWLIST includes "modules/pipeline-executor.js" but background/modules/pipeline-executor.js does not exist.`
Change nothing else in this file — do NOT delete it.

### 4. `tests/install-handler.test.mjs` — the piece #4097 misses

Remove the tests that cover the removed Pipelines seeding, starting with
`initDefaultPipelines: seeds 4 default pipelines when storage empty (ids + step shape)`
at line ~266. Also check the adjacent
`initDefaultPipelines: existing pipelines preserved (no overwrite ...)` test and any
other test in that file that references `toolbelt_pipelines` or `initDefaultPipelines`;
remove those too, since the seeding code no longer exists.

Before removing, confirm with `grep -rn "initDefaultPipelines\|toolbelt_pipelines" background/ sidepanel/`
that no production code still seeds pipelines. If production code DOES still seed
them, then this is a live feature and the test is right — in that case fix the code
path instead and say so in the PR description.

Leave every other test in that file untouched.

### Explicitly OUT of scope — another session owns these, do not touch

Session `5773481294591418578` is live on these files right now. Touching them causes
a merge conflict:

- `background/modules/offscreen-llm-manager.js`, `action-registry.js`, `registered-actions.js`
- `tests/regression/bare-listener-ratchet.test.js`
- `tests/regression/central-router-namespaced-types.test.js`
- `tests/regression/sender-blind-listener-ratchet.test.js`
- `tests/regression/ssrf-hostname-literal-ratchet.test.js`
- `tests/regression/model-suggestions-per-route.test.mjs`
- `tests/writing-companion.test.js` / `.mjs`
- `tests/ollama-proxy-action.test.mjs`
- `tests/ci-regression-harness.test.mjs`

Also out of scope (separate future sessions): `tests/false-security-claims.test.mjs`
(`pentestScopeList` anchor), `tests/cli-agent-bridge-smoke.test.mjs` (`GET /api/fleet`),
and the whole sidepanel cluster (`#702` inline styles, `#703` loading text, All Tools
tab, `settings-patch-serialization`, `sidepanel-page-tool-availability`).

Those tests will still be red when you finish. **That is expected.** Do not fix them
and do not let their redness stop you opening the PR.

### Hard constraints

- Never weaken, skip, delete or loosen a test that covers a feature that still
  exists. The only deletions allowed are tests for code `74f702e3` removed, and you
  must verify that for each one.
- Do not raise any ratchet baseline.
- Do not touch `.github/workflows/` at all.
- Do not reformat or refactor unrelated code. Keep the diff minimal.

> This repository is under the **v2 surface freeze**. Do not add a new `*-hub/`
> directory or standalone hub page, a new `background/modules/` engine that
> polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a
> `sidepanel/tools-catalog.json` entry with no counterpart in
> `omarchy-toolbelt/catalog/tools.json`. CI enforces this
> (`tests/regression/v2-surface-freeze-ratchet.test.js`) and your PR will be red.
> Prefer folding your change into an existing surface. Do **not** add a
> `// ratchet-ok:` comment to get around the gate — that hatch is for reviewed
> exceptions only, and using it without review gets the PR closed.

### Verification — run these and paste the output into the PR description

    pnpm install --frozen-lockfile
    pnpm run lint
    node --test --test-force-exit tests/error-tag-consistency.test.js tests/install-handler.test.mjs
    pnpm test

`pnpm run lint` must pass (this is what the version-drift check gates on).
`tests/error-tag-consistency.test.js` and `tests/install-handler.test.mjs` must both
report zero failures. `pnpm test` will still have failures from the out-of-scope
clusters above — list them under a "Known out-of-scope failures" heading and confirm
none of them are in a file you touched.

PR TITLE: `fix(ci): retire tests for features removed in 74f702e3 + sync package.json version`

In the PR description: list each deleted file with the missing path that justified
it, the install-handler change #4097 missed, and the pasted verification output.
Note that this PR supersedes #4097.
