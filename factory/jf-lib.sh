#!/bin/sh
# Shared helpers for the jules-factory scripts (gen/dispatch/harvest).
# Sourced, not executed directly.

JF_DIR=/opt/data/jules-factory
JF_LEDGER="$JF_DIR/ledger.jsonl"
JF_TASKS="$JF_DIR/tasks.jsonl"
JF_LOG="$JF_DIR/factory.log"
JULES_API_KEY_FILE=/opt/data/.jules_api_key
JULES_API=https://jules.googleapis.com/v1alpha
OWNER=PietjePuh

# Repos the factory will never touch regardless of labels.
# 2026-10-05: AI, N8N---SOC-Workflows, N8n, airplane-sole removed -- the
# 2026-10-04 fleet sync reconciled all NAS clones to GitHub (origin =
# source of truth, per Tim). Toolbelt stays hazardous: ~4k PRs, CI-gated
# merge flow, and its NAS working clone origin was a dead local path
# (fixed 2026-10-06 TIM-6: origin -> github.com, monitoring restored).
HAZARD_REPOS=""

mkdir -p "$JF_DIR"
touch "$JF_LEDGER" "$JF_TASKS"

jf_log() {
  printf '%s|%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$JF_LOG"
}

jf_api_key() {
  cat "$JULES_API_KEY_FILE"
}

jf_is_hazard() {
  repo="$1"
  for h in $HAZARD_REPOS; do
    [ "$h" = "$repo" ] && return 0
  done
  return 1
}

# Append one ledger line under flock (last-entry-per-key wins when read back).
# Args: repo issue action [extra_json_fields_no_braces]
jf_ledger_append() {
  _repo="$1"; _issue="$2"; _action="$3"; _extra="${4:-}"
  (
    flock -w 10 9 || { jf_log "LOCK_TIMEOUT repo=$_repo issue=$_issue action=$_action"; exit 1; }
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [ -n "$_extra" ]; then
      printf '{"ts":"%s","repo":"%s","issue":%s,"action":"%s",%s}\n' "$ts" "$_repo" "$_issue" "$_action" "$_extra" >> "$JF_LEDGER"
    else
      printf '{"ts":"%s","repo":"%s","issue":%s,"action":"%s"}\n' "$ts" "$_repo" "$_issue" "$_action" >> "$JF_LEDGER"
    fi
  ) 9>"$JF_DIR/.ledger.lock"
}

# Last action for a repo#issue key, "" if none ever recorded.
jf_last_action() {
  _repo="$1"; _issue="$2"
  grep "\"repo\":\"$_repo\",\"issue\":$_issue," "$JF_LEDGER" 2>/dev/null | tail -1 | python3 -c '
import sys, json
line = sys.stdin.readline().strip()
print(json.loads(line)["action"] if line else "")
' 2>/dev/null
}

jf_today() { date -u '+%Y-%m-%d'; }

jf_dispatched_today_count() {
  grep "\"action\":\"dispatched\"" "$JF_LEDGER" 2>/dev/null | grep -c "\"ts\":\"$(jf_today)" || true
}

# Count ledger keys whose LAST action is "dispatched" (i.e. still live, no
# terminal entry yet). Cheap approximation of "live sessions" -- ledger is
# the source of truth per the factory design, not a fresh API poll.
jf_live_session_count() {
  python3 -c "
import json
last = {}
try:
    with open('$JF_LEDGER') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            key = (d.get('repo'), d.get('issue'))
            last[key] = d.get('action')
except FileNotFoundError:
    pass
print(sum(1 for v in last.values() if v == 'dispatched'))
"
}

# Extract a field (e.g. session_id) from the "dispatched" ledger entry for
# a repo#issue key -- that's the only entry type that carries it.
jf_ledger_field() {
  _repo="$1"; _issue="$2"; _field="$3"
  grep "\"repo\":\"$_repo\",\"issue\":$_issue,\"action\":\"dispatched\"" "$JF_LEDGER" 2>/dev/null | tail -1 | python3 -c "
import sys, json
line = sys.stdin.readline().strip()
print(json.loads(line).get('$_field', '') if line else '')
" 2>/dev/null
}

jf_open_pr_count_for_repo() {
  gh pr list --repo "$OWNER/$1" --search "in:title [jules #" --state open --json number --jq 'length' 2>/dev/null || echo 0
}
