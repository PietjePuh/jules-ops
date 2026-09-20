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
| `jules-rotate.sh` | Nightly: starts one session on the next repo, rotating personas |
| `repos.priority` | Rotation order for scheduled work, highest value first |
| `prompts/` | Persona prompts: sentinel, palette, bolt — all forbid asking |

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

```
0 4   * * * jules-watch-cron.sh  >>cron.log 2>&1   # release surface
30 4  * * * jules-triage.sh      >>cron.log 2>&1   # stalled-session report
0 */3 * * * jules-stalled.sh     >>cron.log 2>&1   # waiting-on-you alert
0 23  * * * jules-rotate.sh      >>cron.log 2>&1   # one session, next repo
0 8   * * 1 jules-heartbeat.sh   >>cron.log 2>&1   # weekly proof of life
```

All paths are absolute in the real crontab. Host timezone is `Etc/UTC`, so these
are UTC. Output goes to `cron.log`, never `/dev/null`: a failure inside the
notifier itself would otherwise be silent.

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
