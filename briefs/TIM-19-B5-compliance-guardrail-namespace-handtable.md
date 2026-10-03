# TIM-19 B5 — compliance* + guardrail* hand-table entries (18 names)

Repo: PietjePuh/Toolbelt. Branch from `origin/main`, new branch
`bus/compliance-guardrail-handtable`.

Do not ask any questions. Every decision you need is below. If something is
genuinely undecidable, pick the option stated as "default" and say so in the PR
description.

## Merge-order note (do not act on it)

An earlier TIM-19 PR (#4150, `notes.*` family) may still be open when you
start. Branch from current `origin/main` anyway and IGNORE that PR — do not
rebase onto it, do not include its entries. The dispatcher owns a rebase pass
for you after #4150 lands. Your entries live in different keys than #4150's;
a textual append conflict at rebase time is expected and is resolved by
keeping both blocks.

## SURFACE FREEZE (active, this repo)

The v2 plan is a subtraction plan, so new surface is not dispatched at all: no
new `*-hub/` directory or standalone hub page, no new `background/modules/`
engine polling an upstream an `omarchy-toolbelt/bin/*.py` engine already owns,
no `sidepanel/tools-catalog.json` entry without a host-catalog counterpart.

You may NOT self-issue a `// ratchet-ok: <reason>` or `"ratchetOk"` escape
hatch under any circumstances. If you believe you need one, stop and explain
why in the PR description instead of adding it.

This task adds ZERO runtime surface and changes ZERO call sites. It is data
only: one checked-in JSON table plus the generated maps it feeds. Your diff
MUST NOT touch `background/`, `content/`, `*-hub/`, `sidepanel/`,
`manifest.json`, `popup/`, `src/`, or `options/`. If you think you need to,
stop and say so in the PR description instead.

## Background — read before writing code

`main` already has (B1a #4123, B2 #4142, B3 #4148, B4 #4150 — merged or about
to be):

- `scripts/gen-bus-aliases.mjs` — the generator. Rule 0
  (`docs/bus-alias-handtable.json`, exact legacy name → exact canonical,
  checked first) wins over every derived rule. Run it with
  `node scripts/gen-bus-aliases.mjs --write-baseline` to regenerate
  `docs/bus-action-aliases.json` and
  `tests/baselines/bus-alias-unresolved-baseline.json` from the hand table +
  prefix table + current registered actions.
- `docs/bus-alias-handtable.json` — has the B1a/B3 entries plus the B4
  `notes.*` block if #4150 already merged (37 entries before B4, 59 after).
  Whichever count you see at your checkout, ADD the 18 entries below and DO
  NOT touch, reorder, or reformat any existing entry.
- `tests/baselines/bus-alias-unresolved-baseline.json` — 215 unresolved names
  as of 2026-09-26 10:30Z (237 before B4; 215 after B4 removes 22). This PR
  removes exactly the 18 names listed below from this file and leaves every
  other line untouched. This baseline is shrink-only — deleting a resolved
  name's line is the correct and required edit; do not add anything back.
- `tests/regression/bus-alias-map.test.js` — already asserts injectivity
  (no two legacy names collide on one canonical) and append-only-ness
  (`tests/baselines/bus-alias-edges-frozen.json` must stay a subset of the
  current map with unchanged targets). You do not need to edit this test
  file; your new entries just have to pass it.
- `docs/TOOLBELT-BUS-PROTOCOL.md` §2.2 namespace ownership: `sec.` owns
  "Security posture, vault, scanners, IOC, malware, containment". The
  compliance family (asset inventory, evidence capture, compliance auditing
  and monitoring) and the guardrail family (approve/deny gates, policy and
  mode control, guardrail state) are both security-posture surface — this is
  the §2.2 ruling behind every canonical below. Grammar §2.1:
  `action := namespace "." segment ( "." segment ){0,2}`, lowerCamel
  segments, no underscores, max 4 dot-segments total, max 64 chars.

## Goal

Resolve the two largest remaining clean prefix clusters in the unresolved
baseline (compliance* 10, guardrail* 8; measured 2026-09-26 on main) into the
hand table under `sec.compliance.*` and `sec.guardrail.*` sub-namespaces,
following B3/B4's convention: one sub-namespace per source-module family, verb
= lowerCamel tail of the legacy name after stripping the
`compliance`/`guardrail` prefix. Pure naming/data exercise: no privilege-tier
or gating code changes. Introspection (B2, merged) derives tier/surfaces
generically at read time.

## The 18 entries — ship exactly these, nothing more, nothing less

Add exactly this block to `docs/bus-alias-handtable.json` (append at the end
of the object, keep the file valid JSON — validate with
`node -e "JSON.parse(require('fs').readFileSync('docs/bus-alias-handtable.json'))"`
before committing):

```json
"complianceAssetAdd": "sec.compliance.assetAdd",
"complianceAssetRemove": "sec.compliance.assetRemove",
"complianceAssetsList": "sec.compliance.assetsList",
"complianceAssetsProbe": "sec.compliance.assetsProbe",
"complianceAudit": "sec.compliance.audit",
"complianceEvidenceList": "sec.compliance.evidenceList",
"complianceEvidenceSnapshot": "sec.compliance.evidenceSnapshot",
"complianceMonitorGet": "sec.compliance.monitorGet",
"complianceMonitorSet": "sec.compliance.monitorSet",
"complianceMonitorTick": "sec.compliance.monitorTick",
"guardrailApprove": "sec.guardrail.approve",
"guardrailClearLog": "sec.guardrail.clearLog",
"guardrailDeny": "sec.guardrail.deny",
"guardrailRemoveAllowRule": "sec.guardrail.removeAllowRule",
"guardrailRequest": "sec.guardrail.request",
"guardrailSetMode": "sec.guardrail.setMode",
"guardrailSetPolicy": "sec.guardrail.setPolicy",
"guardrailState": "sec.guardrail.state"
```

(The 18 legacy names above are exactly the compliance*/guardrail* entries in
the unresolved baseline as measured 2026-09-26: 10 `compliance*` + 8
`guardrail*`. If any name is absent from the baseline at your checkout, it is
stale — do not add it.)

Two traps to avoid:

- Before committing, verify each legacy name you add still exists as a
  `registerAction()` call site in `background/modules/actions/` at your
  checkout's HEAD. If a name has been renamed or removed since 2026-09-26,
  drop that one entry and say so explicitly in the PR description — do not
  invent an entry for a name that no longer exists (the generator's
  stale-baseline check will catch it anyway, but call it out).
- `guardrailState` maps to `sec.guardrail.state` (a noun, deliberately — it
  is a state read, matching the B3 `*Status`-style reads). Keep it; do not
  invent a verb.

Validate each canonical against §2.1's grammar before committing (namespace
`sec`, 2 further lowerCamel segments after it, ≤64 chars, no underscores) —
all 18 satisfy this by construction.

## What to do

1. Add the (up to) 18 entries to `docs/bus-alias-handtable.json` as shown.
2. Run `node scripts/gen-bus-aliases.mjs --write-baseline` to regenerate
   `docs/bus-action-aliases.json` (grows by exactly the number of entries you
   added) and `tests/baselines/bus-alias-unresolved-baseline.json` (shrinks
   by the same count, from 215 modulo any drift).
3. Diff the regenerated `bus-alias-unresolved-baseline.json` against your
   checkout's parent version and confirm the ONLY lines removed are the
   compliance/guardrail names above. If the generator produced any other
   diff, stop and explain the discrepancy in the PR description rather than
   silently accepting it.
4. Do not touch `tests/baselines/bus-alias-edges-frozen.json` in this PR —
   freezing these edges as a permanent floor is a separate, later decision.

## What this PR deliberately does not do

- No privilege/tier reconciliation and no edits to `PRIVILEGED_ACTIONS` in
  `background/modules/message-handler.js` or its floor baseline.
- No changes to any `registerAction()` call site, name, or options object.
- Does not touch `tests/baselines/bus-alias-edges-frozen.json`.
- Does not resolve any name outside the 18 listed above. The remaining
  unresolved families (TB_* 10, DOMAIN_*/EMAIL_* watch 12, plus scattered
  singletons) are later B6+ work and each needs its own §2.2 ruling — do not
  preempt.

## Verify before you open the PR — quote the output in the description

```
node scripts/gen-bus-aliases.mjs        # must exit 0 against your regenerated baseline
node --test --test-force-exit tests/regression/bus-alias-map.test.js
npm run preflight
npm run security
```

Paste in the PR description: the exact before/after counts
(`docs/bus-action-aliases.json` entries, `bus-alias-unresolved-baseline.json`
entries), and confirmation that the unresolved-baseline diff touches only the
compliance/guardrail lines (or the exact deviation and why).

PR title: `feat(bus): sec.compliance.*/sec.guardrail.* hand-table entries (TIM-19 B5)`.
