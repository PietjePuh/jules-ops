#!/bin/sh
# jules-factory: dispatch -- start Jules sessions for queued tasks within
# budget. Run every 15m, --no-agent (pure script, zero LLM tokens).
#
# Budgets (defaults from the agent-pr-backlog skill's "what worked"):
#   100 sessions/day total, 6 live sessions total, 3 open agent PRs/repo.
# A task is "never re-dispatched" once any ledger entry exists for it --
# re-arming (clearing its ledger entries) is a deliberate manual action,
# never automatic.
set -eu
. /opt/data/scripts/jules-factory/jf-lib.sh

MAX_PER_DAY=100
MAX_LIVE=6
MAX_PR_PER_REPO=3

[ -f "$JULES_API_KEY_FILE" ] || { jf_log "dispatch: ABORT no API key file"; echo "no API key file"; exit 1; }
[ -s "$JF_TASKS" ] || { echo "dispatch: no tasks.jsonl yet (run gen first)"; exit 0; }

dispatched_today=$(jf_dispatched_today_count)
live=$(jf_live_session_count)
dispatched_this_run=0

if [ "$dispatched_today" -ge "$MAX_PER_DAY" ]; then
  jf_log "dispatch: daily budget exhausted ($dispatched_today/$MAX_PER_DAY)"
  echo "dispatch: daily budget exhausted ($dispatched_today/$MAX_PER_DAY)"
  exit 0
fi
if [ "$live" -ge "$MAX_LIVE" ]; then
  jf_log "dispatch: live-session budget full ($live/$MAX_LIVE)"
  echo "dispatch: live-session budget full ($live/$MAX_LIVE)"
  exit 0
fi

# Per-repo open-PR counts, cached once per run (gh calls are not free).
REPO_PR_CACHE="$JF_DIR/.repo_pr_cache.$$"
: > "$REPO_PR_CACHE"
repo_pr_count() {
  r="$1"
  cnt=$(grep "^$r " "$REPO_PR_CACHE" 2>/dev/null | awk '{print $2}')
  if [ -z "$cnt" ]; then
    cnt=$(jf_open_pr_count_for_repo "$r")
    echo "$r $cnt" >> "$REPO_PR_CACHE"
  fi
  echo "$cnt"
}

while IFS= read -r line; do
  [ -z "$line" ] && continue
  repo=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["repo"])')
  issue=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["issue"])')
  title=$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')

  if jf_is_hazard "$repo"; then
    continue
  fi

  already=$(jf_last_action "$repo" "$issue")
  if [ -n "$already" ]; then
    continue
  fi

  [ "$dispatched_today" -ge "$MAX_PER_DAY" ] && break
  [ "$live" -ge "$MAX_LIVE" ] && break

  prcount=$(repo_pr_count "$repo")
  if [ "$prcount" -ge "$MAX_PR_PER_REPO" ]; then
    jf_log "dispatch: skip repo=$repo issue=$issue (repo at PR cap $prcount/$MAX_PR_PER_REPO)"
    continue
  fi

  pr_title="[jules #$issue] $title"
  # 2026-10-05: Jules sandboxes CANNOT read GitHub (404/Bad Credentials on
  # private repos) -- "read the issue" prompts left agents stalling in
  # AWAITING_USER_FEEDBACK asking for requirements. So we inline the issue
  # body, fetched live at dispatch time. Body comes from Tim's own repos;
  # capped at 6000 chars. Untrusted-issue inlining would need a sanitizer.
  ibody=$(gh issue view "$issue" --repo "$OWNER/$repo" --json body --jq .body 2>/dev/null | head -c 6000)
  prompt=$(printf 'Implement this task from %s/%s issue #%s ("%s").\n\nISSUE BODY (acceptance criteria -- your sandbox cannot read GitHub, work from this text):\n%s\n\nRules: follow the repo conventions, make reasonable engineering decisions autonomously, do not ask questions unless truly blocking. When done, open a pull request titled exactly: %s' \
    "$OWNER" "$repo" "$issue" "$title" "$ibody" "$pr_title")

  body=$(python3 -c "
import json, sys
print(json.dumps({
    'prompt': sys.argv[1],
    'sourceContext': {
        'source': f'sources/github/{sys.argv[2]}/{sys.argv[3]}',
        'githubRepoContext': {'startingBranch': 'main'},
    },
    'title': sys.argv[4],
    'requirePlanApproval': False,
    'automationMode': 'AUTO_CREATE_PR',
}))
" "$prompt" "$OWNER" "$repo" "$pr_title")

  resp=$(curl -sS -m 30 -X POST "$JULES_API/sessions" \
    -H "X-Goog-Api-Key: $(jf_api_key)" -H "Content-Type: application/json" \
    -d "$body" -w '\n%{http_code}')
  http_code=$(printf '%s' "$resp" | tail -1)
  resp_body=$(printf '%s' "$resp" | sed '$d')

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    session_id=$(printf '%s' "$resp_body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || echo "")
    extra=$(python3 -c "import json; print(json.dumps({'session_id': '$session_id', 'pr_title': '$pr_title'})[1:-1])")
    jf_ledger_append "$repo" "$issue" "dispatched" "$extra"
    jf_log "dispatch: OK repo=$repo issue=$issue session=$session_id"
    echo "dispatched: $repo#$issue -> $session_id"
    dispatched_today=$((dispatched_today + 1))
    live=$((live + 1))
    dispatched_this_run=$((dispatched_this_run + 1))
  else
    case "$resp_body" in
      *FAILED_PRECONDITION*)
        # Jules enforces one active session per source repo. Another session
        # (often an orphan from a prior dispatch) holds the slot; it will free
        # up when that session goes terminal. Retry next cycle -- not an error.
        jf_log "dispatch: SKIP repo=$repo issue=$issue (repo session slot busy, will retry)"
        echo "skip: $repo#$issue (repo slot busy)"
        ;;
      *)
        jf_log "dispatch: FAILED repo=$repo issue=$issue http=$http_code body=$resp_body"
        echo "dispatch FAILED: $repo#$issue (HTTP $http_code)"
        ;;
    esac
  fi
done < "$JF_TASKS"

rm -f "$REPO_PR_CACHE"
echo "dispatch: $dispatched_this_run new session(s) this run"
