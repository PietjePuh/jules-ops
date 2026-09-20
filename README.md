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
| `jules-stalled.sh` | Alerts on sessions waiting on a human, or failed, beyond a threshold |
| `notify.sh` | Shared Slack notifier, sourced by the cron jobs |

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
0 4   * * * /var/lib/nova-mcp/work/jules-ops/jules-watch-cron.sh >/dev/null 2>&1
0 */3 * * * /var/lib/nova-mcp/work/jules-ops/jules-stalled.sh    >/dev/null 2>&1
```

## Notes

- The published API reference documents source names as `sources/github-owner-repo`;
  the live API returns `sources/github/owner/repo`. `jules.sh` resolves the name by
  listing `/sources` and matching `owner/repo`, so neither format is hardcoded.
- The Jules product changelog is not covered by `jules-watch.sh`: `jules.google`
  serves a challenge page to plain HTTP clients and publishes no feed or sitemap,
  so it only renders through headless Chromium.
- Local state (`state.json`, `stalled-seen.json`) and logs are deliberately not
  tracked; they expire and are rebuilt on the next run.
