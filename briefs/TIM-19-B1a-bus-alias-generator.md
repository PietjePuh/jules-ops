Repo: PietjePuh/Toolbelt. Branch from `main`, new branch `bus/alias-generator`.
Create ONE branch and ONE PR.

Do not ask any questions. Every decision you need is below. If something is
genuinely undecidable, pick the option stated as "default" and say so in the PR
description.

## SURFACE FREEZE (active, this repo)

The v2 plan is a subtraction plan, so new surface is not dispatched at all: no
new `*-hub/` directory or standalone hub page, no new `background/modules/`
engine polling an upstream an `omarchy-toolbelt/bin/*.py` engine already owns,
no `sidepanel/tools-catalog.json` entry without a host-catalog counterpart.

You may NOT self-issue a `// ratchet-ok: <reason>` or `"ratchetOk"` escape hatch
under any circumstances. If you believe you need one, stop and explain why in
the PR description instead of adding it.

This task adds ZERO runtime surface. It is build tooling + data + tests only.
Your diff MUST NOT touch `background/`, `content/`, `*-hub/`, `sidepanel/`,
`manifest.json`, `popup/`, `src/`, or `options/`. If you think you need to, stop
and say so in the PR description instead.

## Goal

Q1 deliverable 1.5 of the v2 plan needs an alias map: every legacy background
action name → one canonical dotted bus action name. This PR builds the
**generator and its CI enforcement**. It does NOT finish the map — see "What
this PR deliberately does not do".

Three properties must be CI-enforced on the map: **total**, **injective**,
**append-only**.

## Files you create

    scripts/gen-bus-aliases.mjs                        the generator
    docs/bus-alias-prefixes.json                       Rule 2's prefix table (durable artifact)
    docs/bus-alias-handtable.json                      Rule 0's explicit per-action assignments
    docs/bus-action-aliases.json                       the generated map (legacy -> canonical)
    tests/baselines/bus-alias-unresolved-baseline.json the shrink-only unresolved set
    tests/baselines/bus-alias-edges-frozen.json        the append-only edge floor
    tests/regression/bus-alias-map.test.js             the tests

Plus `package.json` scripts:

    "bus:aliases":          "node scripts/gen-bus-aliases.mjs"
    "bus:aliases:baseline": "node scripts/gen-bus-aliases.mjs --write-baseline"

## Inputs (this PR: browser side only)

1. Every `registerAction()` name under `background/modules/` (recursive, `.js`).
2. Every `MCP_HANDLERS` type key (find it under `background/modules/`).

**Parse call sites, not source text.** A naive grep over raw source puts three
*comment* strings into the map and, because the map is required to be total,
fails your own build on a docstring. These three MUST NOT appear in any output:

    <name>        background/modules/actions/cms-scan.js       (in a comment)
    name          background/modules/scanner-base.js           (in a comment)
    yourAction    background/modules/actions/registry-introspect.js (in a comment)

Strip `/* */` and `//` comments before matching, or parse properly. Default:
strip comments with a pre-pass, then match
`registerAction(\s*['"\x60]([^'"\x60]+)['"\x60]`.

## Measured facts (verified against main on 2026-09-25 — sanity checks, not targets)

    unique registerAction names            306
    of which UPPER_SNAKE                    34
    of which dotted                          0   (nothing is canonical yet)
    of which contain a colon                 4   fingerprintDefender:{toggle,siteToggle,getStatus,getSeed}
    camelCase names                        272
    MCP_HANDLERS types                      38

    applying Rule 2's seeded table to the 272 camelCase names, longest prefix first:
      Rule 2 matches                        55  -> 54 once the empty-remainder rule below applies
      unresolved                           217  -> 218 with `contain`, then 214 after Rule 0 takes the 4 colon names

    expected unresolved baseline           214

If your number differs by more than a couple, **print your unresolved set and
explain the delta in the PR description**. Do not tune the rules to hit my
number — the number is a check on the extractor, not the target.

## The rules — applied in order, first match wins

### Rule 0 — hand table (explicit wins)

`docs/bus-alias-handtable.json` maps an exact legacy name to an exact canonical
name. Checked first, so it overrides every derived rule. This file is the
durable human-review artifact: the ~214 unresolved names get assigned here in
later PRs, one namespace at a time, and each assignment is a human-reviewed
authorization-tier decision.

Ship it in this PR containing **exactly these four entries and nothing else**:

    "fingerprintDefender:toggle"     -> "sec.fingerprintDefender.toggle"
    "fingerprintDefender:siteToggle" -> "sec.fingerprintDefender.siteToggle"
    "fingerprintDefender:getStatus"  -> "sec.fingerprintDefender.getStatus"
    "fingerprintDefender:getSeed"    -> "sec.fingerprintDefender.getSeed"

Those four are the ruled decision for the colon names: **alias-only**. The
registry keys in `background/` keep their colons — you do not rename a single
call site. The colon lives on the *legacy* side of the map only. Therefore:
the canonical side MUST satisfy the grammar below; the legacy side MUST NOT be
grammar-checked at all. Getting that backwards will make your own test fail on
these four entries.

### Rule 1 — UPPER_SNAKE (mechanical, no table)

Applies to the union of the 34 UPPER_SNAKE registry names and the 38
`MCP_HANDLERS` types (dedupe). Lowercase the first `_`-separated token; if it is
one of the nine namespaces, use it as the namespace and lowerCamel the
remainder. Otherwise look that token up in Rule 2's table. If that lookup also
misses, the name is **unresolved** — never defaulted.

    AI_IMPROVE_TEXT        -> ai.improveText
    AI_AGENT_RUN           -> ai.agent.run
    WEB_EXPOSURE_SCAN      -> web.exposureScan
    WEB_CORS_SCAN          -> web.corsScan
    IOC_EXTRACT            -> sec.ioc.extract          (IOC -> sec via Rule 2's table)
    KALI_SCAN              -> sec.kali.scan
    KALI_SCAN_RESULT       -> sec.kali.scanResult
    DOCKER_HEALTH_STATUS   -> svc.docker.healthStatus

### Rule 2 — camelCase (longest-prefix table)

Match the legacy name against a `prefix -> namespace` table, **longest prefix
first**, and lowerCamel the remainder as the verb. Put the table in
`docs/bus-alias-prefixes.json`; it is a durable checked-in artifact, not a
constant inside the script. Seed it with exactly this and **do not add
prefixes** — growing the table was considered and rejected; the hand table is
where the tail goes.

    sec.        hex cape kali adguard breach burp malware contain audit threat vuln
    sec.vault.  password vault secret apiToken masterPassword
    ai.         ai agent chat llm prompt summari
    web.        scan page tab cors exposure
    dev.        git gitlab snippet repo jwt json base64 hash uuid cidr
    notes.      note kb clip clipboard
    fleet.      fleet device remote
    svc.        docker stack service gateway n8n alert
    media.      media video cast mpris screenshot yt youtube
    fin.        finance trade budget market portfolio

**Empty-remainder edge (important).** If the matched prefix consumes the whole
name, the remainder is empty and the derived canonical would be a bare
namespace like `sec.` — which is not a legal action. Such a name is
**unresolved**, not `sec.`. Exactly one name hits this today: `contain`. Five
more are verbless and land in the unresolved set for the same family of reasons
— `investigate`, `monitors`, `mssp`, `tailscale`, `totp`. Do not invent verbs
for them; leave them unresolved for the hand table.

### Rule 3 — no match

The name goes in the unresolved set. There is deliberately no catch-all
namespace: a silently-defaulted action is an action nobody has decided the
authorization tier for. The generator's exit behaviour is the ratchet below.

### Rule 4 — desktop acts

**Out of scope for this PR.** It is a separate PR against the same generator.
Structure `gen-bus-aliases.mjs` so a second input source can be added without
restructuring, and leave a short comment saying so. Do not vendor anything from
`omarchy-toolbelt` here.

## Canonical grammar (validate every canonical you emit)

    action    := namespace "." segment ( "." segment ){0,2}
    namespace := sec | dev | web | ai | notes | fleet | svc | media | fin
    segment   := [a-z][a-zA-Z0-9]*        lowerCamelCase, no underscores

Max 4 segments including the namespace, total length <= 64. Case-sensitive,
byte-wise comparison — no normalisation and no case-insensitive matching
anywhere (case folding is how the `type:`-alias bypass class gets reintroduced).

## The three CI properties

**Total** ships as a ratchet, because ~214 names cannot be resolved until their
tiers are decided by hand. `tests/baselines/bus-alias-unresolved-baseline.json`
records the currently-unresolved names. The generator exits **non-zero** and
prints the offending names when either:

- a name is unresolved and NOT in the baseline (a new undeclared action), or
- a name is in the baseline but no longer exists (stale baseline entry —
  delete the line in the same PR).

The baseline is **shrink-only**: resolving a name means deleting its line.
`--write-baseline` rewrites it; the test must fail if the committed baseline
does not match what the generator produces.

**Injective** — assert all three, each with its own named test:

- no two legacy names map to the same canonical name;
- no legacy name appears twice as a key. `JSON.parse` silently keeps the last
  duplicate, so check for duplicate keys by scanning the **raw file text**, not
  the parsed object;
- a Rule 0 hand-table entry may not produce a canonical that a derived rule
  already produced for a different legacy name. This is the "alias map cannot
  introduce a collision" requirement — it must fail loudly, with the two
  colliding legacy names in the message. There are zero collisions inside Rule
  2's 55 matches today, so a green run here is meaningful; add a test that
  feeds the generator's pure mapping function a deliberate synthetic collision
  and asserts it throws.

**Append-only** — `tests/baselines/bus-alias-edges-frozen.json` is a
grow-only floor of `legacy -> canonical` edges, same idiom as
`tests/baselines/privileged-actions-floor-baseline.json`. The test asserts every
frozen edge is still present in `docs/bus-action-aliases.json` **with the same
target**. Removing or retargeting an edge fails CI. Adding one is fine.

## Test file constraints

`tests/regression/bus-alias-map.test.js` must **import and execute** the
generator's exported mapping functions and `JSON.parse` the artifacts. It must
NOT be a pile of `assert.match(readFileSync('scripts/gen-bus-aliases.mjs'), /…/)`
source-text regexes — this repo has a ratchet
(`tests/regression/static-only-test-ratchet.test.js`) that fails a new test file
whose assertions are >=60% regexes over a module's source while never importing
it. Export the pure functions from `gen-bus-aliases.mjs` (e.g.
`export function mapName(name, tables)`) and unit-test those directly.

Use `node --test`. The runner has no jsdom.

## What this PR deliberately does not do

Say all of this in the PR description, plainly:

- The map is **not yet total**: the unresolved baseline lands at ~214, not 0.
  This PR ships the enforcement so the count can only fall; the hand
  assignments are later PRs, one namespace at a time.
- No privilege/tier reconciliation. Do NOT read, edit or reason about
  `PRIVILEGED_ACTIONS` in `background/modules/message-handler.js` or its floor
  baseline. That is a separate PR. Removing anything from `PRIVILEGED_ACTIONS`
  fails CI by design.
- No Rule 4 / desktop acts.
- No changes to any `registerAction()` call site, name, or options object.
- No new `chrome.runtime.onMessage.addListener` anywhere (two CI ratchets
  enforce this). You are not adding runtime code at all, so this should be free.

## Verify before you open the PR — quote the output in the description

    npm run fix:node-modules        # only if module resolution fails; do this FIRST, do not conclude the env is broken
    node scripts/gen-bus-aliases.mjs        # must exit 0 against the committed baseline
    node --test --test-force-exit tests/regression/bus-alias-map.test.js
    npm run preflight
    npm run security

`npm run preflight` bundles the empty-catch and innerHTML ratchets plus an
ESLint `no-useless-escape` check that only runs in CI — hand-check your regex
character classes for unnecessary escapes.

Two extra proofs to paste in the PR description:

1. Delete one line from `tests/baselines/bus-alias-unresolved-baseline.json`,
   re-run the generator, show it exits non-zero naming that action, then restore
   the line. This proves the ratchet bites.
2. Show the generator is deterministic: run it twice, `git diff --stat` is empty
   the second time.

Do not run the full test suite and report a count — the reported test count in
this repo is not deterministic and is not a signal. Failures are reported
reliably; counts are not.
