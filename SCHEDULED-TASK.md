# Daily Jules management run

Paste this as a recurring scheduled task in the Claude app. It runs as a Claude
session with the nova and github connectors attached, so no Claude credential is
needed on nova — the deterministic cron jobs in this repo keep running there and
this run handles what needs judgement.

Suggested cadence: daily, 07:00 Europe/Amsterdam, after the 04:00 watch, the
04:30 triage and the 23:00 rotation have run.

---

## Prompt

Manage the Jules pipeline for PietjePuh. Work from
`/var/lib/nova-mcp/work/jules-ops` on nova via the nova connector, and use the
github connector for pull requests.

Do these, in order, and report in one message:

1. Read `jules-stalled.log`, `jules-rotate.log` and `cron.log` since yesterday.
   Say what ran, what was nudged, what escalated, and what failed.
2. Run `./jules-triage.sh` and read the report. For any session escalated after
   two automatic attempts, read its last activity and answer it yourself with
   `./jules.sh msg <id> "<answer>"` — a specific instruction, not the generic
   nudge the sweep already tried. If a session is genuinely undecidable without
   me, leave it and list it.
3. Run `./jules-prs.sh list`. For each repo over the open-PR limit, look at the
   open Jules PRs and tell me which are near-identical to each other and which
   are independent. Do not close anything.
4. Report the top three things I should decide today, with the tradeoff for each.

Rules, in force every run:

- Never create a session for a repo absent from `repos.allow`. `jules.sh`
  enforces this; do not work around it.
- Never close a pull request. Flag duplicates, let me close them. Automated
  closing on file overlap was tried in Toolbelt and rolled back after it closed
  legitimate work.
- Never merge to main unless CI is green on that head commit. A model's reading
  of a diff is not a substitute for a passing test suite.
- Never delete a session, force-push, change a live workflow, or send anything
  outside Slack without asking me first in the report.
- Secrets are `op://` references. Never print a resolved value.
- If a step fails twice, stop retrying it, report what failed and the specific
  fix.
