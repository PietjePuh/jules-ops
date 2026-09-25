Repo: PietjePuh/omarchy-toolbelt. Branch from main. Create ONE branch and ONE PR.

Do not ask any questions. Every decision you need is below. If something is
genuinely undecidable, pick the option stated as "default" and say so in the PR
description.

## SURFACE FREEZE (active, this repo)

The v2 plan is a subtraction plan, so new surface is not dispatched at all: no
new `*-hub/` directory or standalone hub page, no new engine polling an upstream
an `omarchy-toolbelt/bin/*.py` engine already owns, no tool-catalog entry
without a counterpart in the Toolbelt canonical catalog.

You may NOT self-issue a `// ratchet-ok: <reason>` or `"ratchetOk"` escape hatch
under any circumstances. If you believe you need one, stop and explain why in
the PR description instead of adding it. This task adds ZERO tool entries — it
deletes a generator and turns a hand-maintained file into a vendored artifact.

## Context

`catalog/tools.json` is hand-synced against the Toolbelt extension's catalog and
has drifted. The Toolbelt repo now emits ONE canonical artifact,
`catalog/catalog.json`, with a stable content hash and a per-entry `surfaces`
array (`"browser" | "desktop" | "agent"`). Your job is the desktop half: make
this repo's `catalog/tools.json` a GENERATED VIEW of that canonical artifact,
and gate the hash so drift is a red build.

**`catalog/generate.py` in this repo is the drift engine and must be DELETED.**
It rebuilds the catalog from whatever Toolbelt checkout the local Chrome's
`Preferences` file happens to point at, which is exactly how the two copies came
apart. It is replaced, not extended.

## Distribution decision (already made — implement it, do not re-litigate)

**Vendored file + hash.** The vendored `catalog/tools.json` is committed to this
repo and read at runtime. A read-through from `extension.checkout` is REJECTED,
because the Omarchy desktop plugin must keep working on a machine that has no
Toolbelt checkout at all. `bin/toolbelt_agent.py` already reads the vendored
file relative to its own location (`bin/../catalog/tools.json`), which is the
correct behaviour — preserve it.

## Deliverable — exactly these 4 changes

### 1. DELETE `catalog/generate.py`

Remove the file. Remove any reference to it in docs, README, or scripts.

### 2. `catalog/vendor.py` (new — a maintainer tool, NOT a runtime dependency)

Reads a Toolbelt checkout's `catalog/catalog.json`, keeps only entries whose
`surfaces` array contains `"desktop"`, and writes `catalog/tools.json`.

- Takes the Toolbelt checkout path as an argument, defaulting to the
  `extension.checkout` value already in `catalog/tools.json`.
- If the checkout is absent, it must exit with a clear message and a NON-zero
  code. This is a maintainer tool; failing loudly is correct here. Runtime code
  must never call it.
- It must NOT read Chrome's `Preferences` file. That was `generate.py`'s bug.

### 3. `catalog/tools.json` becomes a generated artifact

- Exactly the entries from Toolbelt's canonical catalog carrying the `desktop`
  surface. On the pinned Toolbelt commit that is **191 entries** (down from the
  current 203: 12 entries point at pages deleted from the extension, and the
  remaining delta is accounted for by browser-only entries that were never
  desktop entries).
- Add a top-level `"_comment"` field reading
  `DO NOT EDIT — generated from Toolbelt catalog/catalog.json by catalog/vendor.py`.
  JSON has no comments, so this field is how the header is carried.
- Add a top-level `"source"` object recording provenance:
  `{ "repo": "PietjePuh/Toolbelt", "commit": "<full sha you vendored from>", "hash": "<the canonical catalog's hash field, copied verbatim>" }`.
- PRESERVE the existing `extension` block and the `hubs` array exactly as they
  are. Do not reformat surviving entries, do not change key order, keep 2-space
  indentation.

**If another open PR has already deleted the 12 dead entries**, rebase onto it
rather than reverting its work; your regenerated file supersedes it and must end
at 191 either way.

### 4. `test/test_catalog_hash.py` (new)

Match the style of the existing `test/test_*.py` files in this repo — read two
of them first and follow their conventions: same runner, same assertion style,
no new dependencies. The CI runner globs `test/test_*.py`, so **do NOT add or
edit any GitHub Actions workflow file** — a new test file is picked up
automatically, and a workflow edit would conflict with open PR #21.

It must assert:

1. `catalog/tools.json` parses; `tools` has exactly 191 entries; every entry has
   a non-empty `id` and `path`; all `id`s are unique.
2. The top-level `_comment` and `source` fields are present, and
   `source.hash` is a 64-char lowercase hex string.
3. **The hash cross-check, with the skip that matters.** Resolve the Toolbelt
   checkout from `extension.checkout`. **If that directory does not exist, SKIP
   this assertion and still PASS.** The desktop plugin has to work on a machine
   with no Toolbelt checkout, so a missing checkout is a valid state, never a
   failure. When the directory DOES exist: read its `catalog/catalog.json`,
   recompute the hash (sha256, lowercase hex, over `json.dumps` of the `tools`
   array sorted ascending by `id` with every entry's keys sorted alphabetically,
   using separators that match Toolbelt's `JSON.stringify` — no spaces:
   `separators=(',', ':')`), and assert it equals both that file's own `hash`
   field and this repo's `source.hash`.
4. When the checkout exists, also assert every vendored entry's `path` resolves
   to a real file under it.

Point 3's skip behaviour is the load-bearing one. Get it right, and prove it
both ways in the PR description.

## Do NOT do these

- Do NOT add or edit any file under `.github/`. PR #21 owns that.
- Do NOT add, rename, or recategorise any tool entry.
- Do NOT make `bin/toolbelt_agent.py` depend on a Toolbelt checkout being
  present. Verify `url` still resolves from the vendored file alone.
- Do NOT read Chrome's `Preferences` file anywhere in new code.
- Do NOT reformat the `extension` block or the `hubs` array.

## Verification — run these and paste the REAL output into the PR description

    python3 -c "import json;d=json.load(open('catalog/tools.json'));print('tools',len(d['tools']),'hash',d['source']['hash'][:12])"
    python3 test/test_catalog_hash.py
    python3 test/smoke_dashboard.py
    python3 test/smoke_orchestrator.py
    python3 bin/toolbelt_agent.py url ai-hub-ai-hub

Expected: `tools 191`.

**Prove the checkout-absent path (acceptance criterion — paste both runs):** run
`test/test_catalog_hash.py` once normally, then once with `extension.checkout`
temporarily pointed at a non-existent directory, and show the second run still
PASSES with the cross-check skipped. Also run the
`bin/toolbelt_agent.py url` command in that second state and show it still
resolves. Revert the temporary edit before committing.

**Prove the gate bites:** change one character of `source.hash`, run
`test/test_catalog_hash.py` with the real checkout present, and show it FAILS.
Then restore it and show it passes. A gate you have not seen fail is not a gate.

## Note for the PR description (state this honestly, do not paper over it)

Vendored-plus-hash makes drift impossible to merge SILENTLY — a stale vendored
copy is a red build on both sides. It does not make adding a tool literally
zero-touch across the two repos: it leaves one mechanical, CI-enforced step
(run `catalog/vendor.py`, commit the result). Closing that last step needs a
cross-repo automation that opens the PR for you, which is deliberately OUT OF
SCOPE here. Say so in the PR body rather than implying full automation.

Title the PR: "feat(catalog): vendor the canonical Toolbelt catalog + hash gate, delete generate.py (TIM-17)".
