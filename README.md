# jules-ops

Unattended operation of [Jules](https://jules.google), Google's asynchronous
coding agent, from the nova host. Secrets are resolved at run time from
1Password via the host service account, so no job needs an interactive step.

## Scripts

| File | Purpose |
| --- | --- |
| `jules.sh` | Thin wrapper over the Jules REST API (`v1alpha`) |
| `jules-watch.sh` | Snapshot + diff of the public Jules release surface (GitHub, npm) |
| `jules-watch-cron.sh` | Unattended runner for `jules-watch.sh`, notifies on change or failure |
| `jules-stalled.sh` | Orchestrator: approves plans, nudges waiting sessions, escalates after 2 tries |
| `jules-triage.sh` | Read-only report of every stalled session and its last message |
| `notify.sh` | Shared Slack notifier, sourced by the cron jobs |
| `jules-unblock.sh` | Manual nudge for specific session ids |
| `jules-heartbeat.sh` | Weekly proof of life, so silence means idle and not dead |
| `jules-prs.sh` | Counts, groups, readies and closes open Jules PRs |
| `jules-rotate.sh` | Starts sessions on every eligible repo each pass (pinned repos first), up to the live 100/day quota |
| `jules-archive.sh` | Archives every completed/failed session's prompt + outcome + PR link to `jules-history.jsonl` |
| `jules-autopilot.sh` | One unattended pass for any fleet host: sweep, then rotate (rotate.sh self-limits to the daily quota), then archive |
| `jules-status.sh` | Read-only snapshot for the scheduled run: job logs, escalated/held sessions, PR backlog, rotation position |
| `with-secrets.sh` | Sources the fleet op service-account env file, then execs the real job (for cron's empty environment) |
| `repos.priority` | Rotation order for scheduled work, highest value first |
| `repos.pinned` | Repos guaranteed a slot every pass, before round-robin, at a higher open-PR ceiling — so the busiest repo (Toolbelt) never waits behind 13 others |
| `repos.allow` | Fail-closed allowlist of repos a session may be created against |
| `prompts/` | Persona prompts: sentinel, palette, bolt — all forbid asking |

## Working in this repo

More than one agent works here at once. Each has its own git work tree under
`~/github/.worktrees/<agent>/jules-ops`; `~/github/jules-ops` stays on `main` and
is for reading. See [WORKTREES.md](WORKTREES.md) — sharing one checkout silently
swapped `repos.allow` under a running dispatch on 24/09/2026.

## Secrets

| Purpose | Reference | Override |
| --- | --- | --- |
| Jules API key | `op://Agentforce/Jules api/password` | `JULES_KEY_REF` or `JULES_API_KEY` |
| Slack webhook | `op://Agentforce/Slack Webhook - Titan/Webhook URL` | `SLACK_REF` |

## Usage

```
./jules.sh sources
./jules.sh ls [pageSize]
./jules.sh get <sessionId>
./jules.sh activities <sessionId> [sinceRFC3339]
./jules.sh new <owner/repo> <prompt> [--branch B] [--title T] [--auto-pr] [--plan-approval]
./jules.sh msg <sessionId> <text>
./jules.sh approve <sessionId>
./jules.sh rm <sessionId>
```

Set `JULES_NOTIFY_DRYRUN=1` on either cron job to print the Slack payload
instead of posting it. `./jules-watch-cron.sh test` posts a one-line probe
through the real notification path.

## Schedule

Host timezone is `Etc/UTC`. The scheduled Claude task runs at 07:00
Europe/Amsterdam, which is 05:00 UTC while CEST is in force, so the cron jobs
are stacked in the 45 minutes before that and their output is fresh when the
task reads it.

```
15 4  * * * jules-watch-cron.sh   # release surface
30 4  * * * jules-stalled.sh      # sweep, immediately pre-run
45 4  * * * jules-triage.sh       # stalled-session report
50 4  * * 1 jules-heartbeat.sh    # weekly, lands in the same window
0 */3 * * * jules-stalled.sh      # sweep through the day
```

Note (2026-09-25): on fastbelt none of the above are in an active crontab or
systemd timer — `jules-autopilot.timer` (every 15 min) now runs sweep, rotate,
and archive as one pass and supersedes the old `jules-stalled.sh`/`jules-rotate.sh`
lines above. `jules-watch-cron.sh`/`jules-triage.sh`/`jules-heartbeat.sh` are
not wired into anything active on this host — check nova before assuming this
block is live anywhere.

All output appends to `cron.log`, never `/dev/null`. When CET returns in October
the task moves to 06:00 UTC and the gap widens by an hour; the ordering still
holds.

## Notes

- The published API reference documents source names as `sources/github-owner-repo`;
  the live API returns `sources/github/owner/repo`. `jules.sh` resolves the name by
  listing `/sources` and matching `owner/repo`, so neither format is hardcoded.
- The Jules product changelog is not covered by `jules-watch.sh`: `jules.google`
  serves a challenge page to plain HTTP clients and publishes no feed or sitemap,
  so it only renders through headless Chromium.
- Local state (`state.json`, `stalled-seen.json`), logs and triage reports are
  deliberately not tracked; they expire and are rebuilt on the next run.
- The Jules REST API exposes sessions, activities and sources only. Scheduled
  tasks are a web-UI feature with no API surface, so recurring work that must be
  version-controlled has to be driven from cron here via `jules.sh new`.
- `jules-rotate.sh` refuses to start a second session on a repo that already has
  one live or stalled, so an unanswered question blocks that repo only and the
  rotation moves on to the next one.
- `jules-stalled.sh` acts rather than reports: `AWAITING_PLAN_APPROVAL` is
  approved, `AWAITING_USER_FEEDBACK` is told to decide and ship, `FAILED` is
  reported once. Two attempts per unchanged `updateTime`, then one escalation to
  Slack and no further retries until the session actually moves.
- `jules.sh new` refuses any repo absent from `repos.allow`, and refuses outright
  if that file is missing. `repos.priority` must stay a subset of it, or rotation
  will pick a repo the guard then rejects.
- Session titles and activity text are written by Jules, not by us, so control
  characters are stripped before that text reaches Slack or a triage report.
- Jules opens its pull requests as drafts. A draft runs no workflows, so an
  auto-merge workflow keyed on a successful check run never fires and the PR
  sits forever. `jules-prs.sh ready <repo>` marks them ready via the GraphQL
  `markPullRequestReadyForReview` mutation, which is what starts CI. Verified on
  PietjePuh/BackgroundRemoval#328: draft=false, and a workflow queued within a
  minute.
- Rotation applies backpressure rather than de-duplicating after the fact: it
  skips any repo with `JULES_MAX_OPEN_PRS` (default 3) or more open Jules PRs,
  and notifies when a run starts nothing instead of exiting silently. Closing
  duplicate PRs by heuristic was tried in PietjePuh/Toolbelt's `dedupe-prs.yml`
  and rolled back — overlap on a shared file is too weak a signal and it closed
  legitimate work.
- `jules-prs.sh close` is dry-run unless `--confirm`. It comments the reason on
  the pull request before closing it, so the decision is auditable and the close
  is reopenable. `--superseded` keeps the highest-numbered PR per normalised
  title and closes the rest; that is a far stronger signal than the file-overlap
  heuristic Toolbelt rolled back, because the titles are byte-identical.
  `--conflicted` closes only PRs whose `mergeable_state` is `dirty` and which are
  older than `--age-days`.

## Force-pushing a Jules branch

A Jules session pins the commit it started from and never rebases. If it writes
again after you force-push, it re-applies its diff from that pinned base and
silently reverts everything merged since. `COMPLETED` does not mean the session
is finished with the branch — check the session's update time, not its state.
Two documented incidents of exactly this are written up in
Avicennasis/jules-mcp's README (`GrantLoft#361`, `rDNSFix#88`), where a squash
merge reverted six already-merged PRs.

The REST API has no archive endpoint — `sessions` supports create, list, get,
delete, sendMessage and approvePlan only — so the only way to guarantee a
session cannot write again is `jules.sh rm <id>`. Procedure:

1. Find the session for that branch and delete it.
2. Force-push the rework.
3. Re-read the PR head and confirm it is still your commit before merging.

The structurally safer alternative is to open a fresh PR from a branch Jules has
no session for, and close theirs.
- An archived repository is read-only: pull requests cannot be closed or merged
  and workflows do not run. `AI`, `Main` and `ract` were archived and have been
  dropped from `repos.priority` and `repos.allow`. Unarchive them on GitHub
  before adding them back.
- The sessions endpoint caps a page at 100 and the account holds several hundred
  sessions, so a single request silently hides the rest. `jules.sh ls` pages
  until it has what was asked for; every caller now asks for 500. Before this
  fix the sweep, the triage and rotation's busy check were blind to 42 stalled
  sessions sitting past the first page.
- There is no archive endpoint. Sessions accumulate indefinitely and the only
  way to remove one is `jules.sh rm`.
- The sweep honours the same open-PR limit as rotation. A stalled session whose
  repo is already over the limit is reported as held rather than nudged, because
  answering it produces another pull request into a repo that cannot absorb one.
  The session's repo is cached in the state file so the backlog is not
  re-resolved on every run.
- `JULES_NOTIFY` selects the channel: `log` (default) appends alerts to
  `notify.log`, `slack` posts through the webhook, `off` discards them. The
  scheduled task is the notification channel, so alerts are written where it
  reads them; `jules-status.sh` surfaces `notify.log` and the run clears it.
