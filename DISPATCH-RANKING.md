# Dispatch ranking rules

How Dispatch decides what Jules works on next. This file is the SSOT for
ranking; the persona prompts in `prompts/` carry the constraints that have to
travel with every session, and `repos.priority` carries the repo rotation order.

## Active: the v2 surface freeze (from 24/09/2026)

The v2 plan ([TIM-7], Q1 deliverable 1.7 / [TIM-16]) is a **subtraction plan**:
8 duplicated engines → 0, 2 catalogs → 1, 11 hub pages → 0 standalone surfaces.
The night-build loop and ordinary feature work were adding surface faster than
consolidation removed it, which moves the target away every week it runs. The CI
side of the brake is `tests/regression/v2-surface-freeze-ratchet.test.js` in
`Toolbelt`. This file is the other half: **the pipeline must stop generating the
work the ratchet blocks.** A gate that only fires after Jules has spent a session
is a gate that wastes sessions.

Scope: `PietjePuh/Toolbelt` and `PietjePuh/omarchy-toolbelt`. Other repos in
`repos.priority` rank normally.

### Not dispatched — do not write a brief for these

- A new `*-hub/` directory, or a new standalone hub page, in `Toolbelt`.
- A new `background/modules/` engine that polls an upstream already owned by an
  `omarchy-toolbelt/bin/*.py` engine: news/RSS, Notion/notes, AI-usage, finance,
  docker stacks, findings ledger, agents view, OS security posture.
- A new tool registered in `sidepanel/tools-catalog.json` with no counterpart in
  `omarchy-toolbelt/catalog/tools.json`.

If a request implies one of these, it is a **product decision**, not a backlog
item — it goes to [AI oriscator rights hand of the SEO] as an issue-thread
interaction, not to Jules. The escape hatch (`// ratchet-ok: <reason>`) exists
for reviewed exceptions and is **not** Dispatch's to spend: a brief may not
instruct Jules to write one.

### Rank order while the freeze holds

1. **Subtraction** — removes a duplicate engine, merges two surfaces into one,
   moves an engine host-side, or reconciles the two catalogs. Ranks above
   everything, including security work of equal size, because it is the only
   class that makes the end-of-plan merge smaller.
2. **Ratchet and gate work** — anything that makes a freeze rule cheaper to obey
   or harder to evade.
3. **Security and correctness fixes** inside existing surface.
4. **Feature work** inside existing surface.
5. **Everything else.**

A subtraction item that deletes a baseline line in
`tests/baselines/v2-surface-freeze-baseline.json` is the shape to look for —
that deletion is the freeze visibly making progress, and it is the single best
evidence a session did real work.

### Every brief states the freeze

Any brief for `Toolbelt` or `omarchy-toolbelt` carries, verbatim:

> This repository is under the **v2 surface freeze**. Do not add a new `*-hub/`
> directory or standalone hub page, a new `background/modules/` engine that
> polls an upstream an `omarchy-toolbelt/bin/*.py` engine already owns, or a
> `sidepanel/tools-catalog.json` entry with no counterpart in
> `omarchy-toolbelt/catalog/tools.json`. CI enforces this
> (`tests/regression/v2-surface-freeze-ratchet.test.js`) and your PR will be red.
> Prefer folding your change into an existing surface. Do **not** add a
> `// ratchet-ok:` comment to get around the gate — that hatch is for reviewed
> exceptions only, and using it without review gets the PR closed.

Run `npm run preflight` before pushing; it runs the freeze ratchet locally.

### Lifting the freeze

The freeze ends when the v2 Q1 consolidation deliverables land, not on a date.
When it lifts, delete this section — leaving a stale freeze in force is how a
brake becomes a superstition.
