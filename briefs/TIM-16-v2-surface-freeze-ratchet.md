# TIM-16 — build the CI half of the v2 surface freeze

Surface: Toolbelt. Rank: **2** (ratchet/gate work — makes a freeze rule harder to evade).
Status: **queued, not dispatched.** Two Toolbelt sessions are live; dispatch when a slot frees.

## Why this exists

`DISPATCH-RANKING.md` and every Toolbelt brief tell Jules, verbatim, that the v2
surface freeze is enforced by `tests/regression/v2-surface-freeze-ratchet.test.js`
and that a violating PR "will be red".

**That file does not exist**, on any branch of `PietjePuh/Toolbelt`. Neither does
`tests/baselines/v2-surface-freeze-baseline.json`. Verified 24/09/2026 by repo
search and branch listing. The freeze currently has only a dispatch half — my
briefs — and nothing stops a session that never read one. This brief builds the
missing half.

Current counts on `main` @ `b0daf9d1`, which are the ceilings to freeze:

- `*-hub/` directories: **11** (`ai-hub`, `cyberops-hub`, `devtools-hub`,
  `exam-trainer-hub`, `finance-hub`, `integrations-hub`, `learning-hub`,
  `media-hub`, `productivity-hub`, `rss-hub`, `security-hub`)
- `sidepanel/tools-catalog.json` entries: **198**
- `background/modules/*.js`: **426**

## The brief

Repo: `PietjePuh/Toolbelt`. Base branch: `main`. Work on a new branch and open ONE
pull request. Do NOT push to main. Do NOT merge.

You must NOT ask any questions. Every decision is made below.

### Follow the house ratchet pattern exactly

Read `tests/regression/bare-listener-ratchet.test.js` first and copy its shape:
a leading comment block explaining *why* the ratchet exists and how to lower it,
a `BASELINE`/baseline-file constant with a dated comment, enumeration via
`git ls-files` (never a filesystem walk — build artifacts must not inflate counts),
and `node:test` + `node:assert/strict`.

Also read two existing baseline-file ratchets to copy the JSON convention:
`tests/baselines/storage-keys-baseline.json` and
`tests/baselines/static-only-tests-baseline.json`, plus whichever tests consume them.

### Create `tests/baselines/v2-surface-freeze-baseline.json`

A JSON object recording the frozen inventory, generated from `main` as it stands:

```json
{
  "hubDirectories": ["ai-hub", "cyberops-hub", "..."],
  "toolsCatalogIds": ["...every id in sidepanel/tools-catalog.json..."],
  "backgroundModules": ["...every git-tracked background/modules/*.js basename..."]
}
```

Use whatever stable identity field `sidepanel/tools-catalog.json` entries carry
(it is a 198-element array — read it and use its real id field; do not invent one).
Sort every array so the diff of a future change is readable.

### Create `tests/regression/v2-surface-freeze-ratchet.test.js`

Four tests. Every one must **fail on addition and pass on removal** — this is a
subtraction ratchet, so deleting a baseline line is always allowed and is the
point.

1. **No new `*-hub/` directory.** Enumerate top-level `*-hub/` dirs via
   `git ls-files`. Any directory not in `hubDirectories` fails, naming it. A
   baseline entry with no directory on disk must also fail, with a message telling
   the author to delete the stale line — the list ratchets DOWN.

2. **No new `background/modules/` engine.** Any git-tracked
   `background/modules/*.js` not in `backgroundModules` fails, with a message
   naming the file and pointing at the upstreams an `omarchy-toolbelt/bin/*.py`
   engine already owns: news/RSS, Notion/notes, AI-usage, finance, docker stacks,
   findings ledger, agents view, OS security posture. Same stale-entry rule.

3. **No new `sidepanel/tools-catalog.json` entry.** Any id not in
   `toolsCatalogIds` fails. Same stale-entry rule.

4. **The escape hatch is bounded.** Count `// ratchet-ok:` comments across
   git-tracked source. Freeze the current count as a `RATCHET_OK_BASELINE`
   constant. The count may only go DOWN. A rising count fails with: the hatch is
   for reviewed exceptions only, and adding one without review gets the PR closed.

Every failure message must state the current count, the baseline, and the exact
remedy — copy the tone of `bare-listener-ratchet.test.js`, which is the best
example in the repo.

### Wire it into preflight

`scripts/preflight.cjs` already runs a selected set of ratchets (see the `capture(...)`
calls around lines 243-250). Add
`node --test tests/regression/v2-surface-freeze-ratchet.test.js` alongside them, in
the same style, so `npm run preflight` catches a violation before push. Change
nothing else in that file.

### Hard constraints

- The ratchet must be **green on `main` as it stands**. You are freezing the current
  inventory, not proposing a smaller one. Do not delete any hub, module, or catalog
  entry in this PR.
- Do not add a `// ratchet-ok:` comment anywhere.
- Do not touch `.github/workflows/` — the test runs through the existing
  `tests/regression/` discovery, which `tests/ci-regression-harness.test.mjs`
  already sweeps.
- Do not reformat or refactor unrelated code.
- `main` is red right now from unrelated clusters. Your PR will inherit that. Ignore
  it; only your own files must be green.

### Out of scope — other sessions own these files

`background/modules/offscreen-llm-manager.js`, `action-registry.js`,
`registered-actions.js`, `tests/regression/bare-listener-ratchet.test.js` (read only),
`tests/regression/central-router-namespaced-types.test.js`,
`tests/regression/sender-blind-listener-ratchet.test.js`,
`tests/regression/ssrf-hostname-literal-ratchet.test.js`,
`tests/regression/model-suggestions-per-route.test.mjs`, `tests/writing-companion.test.*`,
`tests/ollama-proxy-action.test.mjs`, `tests/install-handler.test.mjs`,
`tests/error-tag-consistency.test.js`, `package.json`.

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
    node --test --test-force-exit tests/regression/v2-surface-freeze-ratchet.test.js
    npm run preflight

Then **prove the ratchet actually bites** — this is the part that matters, and the
PR is not done without it:

    mkdir -p fake-hub && touch fake-hub/index.html && git add fake-hub
    node --test --test-force-exit tests/regression/v2-surface-freeze-ratchet.test.js   # MUST FAIL, naming fake-hub
    git rm -r --cached fake-hub && rm -rf fake-hub
    node --test --test-force-exit tests/regression/v2-surface-freeze-ratchet.test.js   # MUST PASS again

Paste both runs. A ratchet that passes but never fails is worse than no ratchet,
so the failing run is required evidence.

PR TITLE: `test(freeze): add the v2 surface freeze ratchet + baseline`

In the PR description: state the three frozen counts (11 hubs / 198 catalog entries /
426 background modules), explain that deleting a baseline line is always allowed and
is how the freeze shows progress, and paste both verification runs.
