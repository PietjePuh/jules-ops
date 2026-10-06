# jules-factory (jf-*)

Zero-token LLM-free factory that turns GitHub issues labelled `jules` across
all PietjePuh repos into merged PRs. Runtime home: `/opt/data/scripts/jules-factory/`
(live copy referenced by Hermes cronjobs) — this directory is the versioned
source of truth; changes land here via PR or direct push after proving them
in the runtime copy.

## Pipeline
| Script | Cadence (Hermes cron) | What it does |
|---|---|---|
| `jf-gen.sh` | 60m | Rebuild `tasks.jsonl` from all open `jules`-labelled issues (live discovery via `gh search issues` — no hardcoded repo list) |
| `jf-dispatch.sh` | 15m | Start Jules sessions for queued tasks. Budgets: 100/day, 6 live, 3 open agent PRs/repo. Never re-dispatches a ledgered task |
| `jf-harvest.sh` | 15m | Poll live sessions; on completion ready the PR (delete session) |
| `jf-merge.sh` | 15m | Merge green, clean `[jules #N]` PRs (squash) |

## State (runtime, not committed)
- `ledger.jsonl` — append-only dispatch state, last-entry-per-key wins
- `tasks.jsonl` — current queue
- `factory.log` — append log
- Jules API key: runtime file `/opt/data/.jules_api_key` (never commit)

## Guarantees
- `HAZARD_REPOS` (currently `Toolbelt`) is the only static list — everything
  else is discovered live each gen run.
- A task with any ledger entry is never auto-re-dispatched; re-arming is a
  deliberate manual action.
