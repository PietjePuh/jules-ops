#!/bin/sh
# jules-factory: harvest -- state machine for dispatched tasks.
#   draft -> ready (marks ready for review, starts CI)
#   ready + green + MERGED -> done (close issue, delete session)
#   ready + explicit fail (1st time) -> retried (one grace cycle)
#   ready + explicit fail (2nd time) -> abandoned (close PR, issue stays open)
#   no PR + Jules session terminal (FAILED/COMPLETED) -> failed
# Never calls `gh pr merge` itself -- a green, non-draft PR with no fail is
# left for either the repo's own auto-merge workflow or Tim to merge by
# hand. Run every 15m, --no-agent (pure script, zero LLM tokens).
set -eu
. /opt/data/scripts/jules-factory/jf-lib.sh

[ -s "$JF_LEDGER" ] || { echo "harvest: empty ledger, nothing to do"; exit 0; }

# Keys whose LAST action is a non-terminal one (dispatched/readied/retried).
python3 -c "
import json
last = {}
with open('$JF_LEDGER') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        last[(d['repo'], d['issue'])] = d
for (repo, issue), d in last.items():
    if d.get('action') in ('dispatched', 'readied', 'retried'):
        print(f\"{repo}\t{issue}\t{d.get('action')}\")
" > "$JF_DIR/.harvest_live.$$"

ready_green_report=""
n_done=0; n_abandoned=0; n_failed=0; n_readied=0

while IFS="$(printf '\t')" read -r repo issue last_action; do
  [ -z "$repo" ] && continue

  pr_json=$(gh pr list --repo "$OWNER/$repo" --search "in:title [jules #$issue]" --state all \
    --json number,isDraft,state,mergeStateStatus,url --jq '.[0]' 2>/dev/null || echo "")

  if [ -z "$pr_json" ] || [ "$pr_json" = "null" ]; then
    # No PR yet. Only treat as failed once the Jules session itself is terminal.
    session_id=$(jf_ledger_field "$repo" "$issue" "session_id")
    if [ -n "$session_id" ]; then
      state=$(curl -sS -m 20 -H "X-Goog-Api-Key: $(jf_api_key)" "$JULES_API/$session_id" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || echo "")
      case "$state" in
        AWAITING_USER_FEEDBACK)
          # Session wants input. Two flavors: pending plan (approvePlan
          # resolves it) or the agent ASKED A QUESTION (approvePlan 404s --
          # only sendMessage answers). Try approve, and if the session is
          # still waiting it was a question: answer with an autonomy
          # directive so the factory never stalls on silence. Idempotent,
          # no ledger append -- stays live-tracked.
          curl -sS -m 20 -X POST -H "X-Goog-Api-Key: $(jf_api_key)" \
            -H "Content-Type: application/json" -d '{}' \
            "$JULES_API/$session_id:approvePlan" >/dev/null 2>&1 || true
          sleep 3
          state2=$(curl -sS -m 20 -H "X-Goog-Api-Key: $(jf_api_key)" "$JULES_API/$session_id" \
            | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null || echo "")
          if [ "$state2" = "AWAITING_USER_FEEDBACK" ]; then
            answer="Proceed autonomously with your best judgment based on the requirements in the original prompt. If a detail is ambiguous, pick the simplest reasonable option and note the decision in the PR description. Do not wait for further input."
            python3 -c "
import json, subprocess
key = open('$JULES_API_KEY_FILE').read().strip()
r = subprocess.run(['curl','-sS','-m','30','-X','POST',
  '-H','X-Goog-Api-Key: '+key,'-H','Content-Type: application/json',
  '-d', json.dumps({'prompt': '''$answer'''}),
  '$JULES_API/$session_id:sendMessage'], capture_output=True, text=True)
" || true
            jf_log "harvest: ANSWERED repo=$repo issue=$issue session=${session_id##*/}"
          else
            jf_log "harvest: APPROVED repo=$repo issue=$issue session=${session_id##*/}"
          fi
          ;;
        FAILED|COMPLETED)
          jf_ledger_append "$repo" "$issue" "failed" "\"detail\":\"no PR, session state $state\""
          jf_log "harvest: FAILED repo=$repo issue=$issue (session terminal, no PR)"
          n_failed=$((n_failed + 1))
          ;;
      esac
    fi
    continue
  fi

  pr_num=$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')
  is_draft=$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["isDraft"])')
  pr_state=$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')

  if [ "$pr_state" = "MERGED" ]; then
    jf_ledger_append "$repo" "$issue" "done" "\"pr\":$pr_num"
    gh issue close "$issue" --repo "$OWNER/$repo" -c "Closed by jules-factory: merged in #$pr_num." >/dev/null 2>&1 || true
    session_id=$(jf_ledger_field "$repo" "$issue" "session_id")
    [ -n "$session_id" ] && curl -sS -m 20 -X DELETE -H "X-Goog-Api-Key: $(jf_api_key)" "$JULES_API/$session_id" >/dev/null 2>&1 || true
    jf_log "harvest: DONE repo=$repo issue=$issue pr=$pr_num"
    n_done=$((n_done + 1))
    continue
  fi

  if [ "$pr_state" = "CLOSED" ]; then
    # Closed without merging (by Tim or a prior abandon) -- stop tracking.
    jf_ledger_append "$repo" "$issue" "abandoned" "\"pr\":$pr_num,\"detail\":\"closed-not-merged\""
    n_abandoned=$((n_abandoned + 1))
    continue
  fi

  if [ "$is_draft" = "True" ] || [ "$is_draft" = "true" ]; then
    node_id=$(gh pr view "$pr_num" --repo "$OWNER/$repo" --json id --jq .id 2>/dev/null || echo "")
    if [ -n "$node_id" ]; then
      gh api graphql -f query='mutation($id:ID!){markPullRequestReadyForReview(input:{pullRequestId:$id}){pullRequest{number isDraft}}}' -f id="$node_id" >/dev/null 2>&1 || true
      jf_ledger_append "$repo" "$issue" "readied" "\"pr\":$pr_num"
      jf_log "harvest: READIED repo=$repo issue=$issue pr=$pr_num"
      n_readied=$((n_readied + 1))
    fi
    continue
  fi

  # Non-draft, open, not merged: check CI.
  checks=$(gh pr checks "$pr_num" --repo "$OWNER/$repo" --json state 2>/dev/null || echo "[]")
  has_fail=$(printf '%s' "$checks" | python3 -c '
import json, sys
try:
    checks = json.load(sys.stdin)
except Exception:
    checks = []
print("1" if any(str(c.get("state","")).upper() in ("FAILURE","ERROR") for c in checks) else "0")
')
  all_pending=$(printf '%s' "$checks" | python3 -c '
import json, sys
try:
    checks = json.load(sys.stdin)
except Exception:
    checks = []
if not checks:
    print("1")
else:
    print("1" if all(str(c.get("state","")).upper() in ("PENDING","QUEUED","IN_PROGRESS") for c in checks) else "0")
')

  if [ "$has_fail" = "1" ]; then
    if [ "$last_action" = "retried" ]; then
      gh pr close "$pr_num" --repo "$OWNER/$repo" -c "Closed by jules-factory: CI still red after one grace cycle." >/dev/null 2>&1 || true
      jf_ledger_append "$repo" "$issue" "abandoned" "\"pr\":$pr_num,\"detail\":\"ci-red-twice\""
      jf_log "harvest: ABANDONED repo=$repo issue=$issue pr=$pr_num (CI red twice)"
      n_abandoned=$((n_abandoned + 1))
    else
      jf_ledger_append "$repo" "$issue" "retried" "\"pr\":$pr_num,\"detail\":\"ci-red-first-time\""
      jf_log "harvest: grace cycle repo=$repo issue=$issue pr=$pr_num (CI red, 1st time)"
    fi
    continue
  fi

  if [ "$all_pending" = "1" ]; then
    continue
  fi

  # Green and not merged: report, never auto-merge from this script.
  ready_green_report="$ready_green_report\n$OWNER/$repo#$pr_num (issue #$issue)"
done < "$JF_DIR/.harvest_live.$$"

rm -f "$JF_DIR/.harvest_live.$$"

echo "harvest: readied=$n_readied done=$n_done abandoned=$n_abandoned failed=$n_failed"
if [ -n "$ready_green_report" ]; then
  echo "harvest: GREEN, NOT MERGED (no auto-merge workflow or still settling) --$ready_green_report"
fi
