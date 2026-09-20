#!/usr/bin/env bash
# One read-only snapshot for a scheduled management run: recent job activity,
# anything waiting on a human, the pull-request backlog, and live sessions.
# Prints plain sections; makes no changes and never posts to Slack.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINCE_H="${JULES_STATUS_SINCE_H:-26}"

sec() { printf '\n== %s ==\n' "$1"; }
tail_or() { [ -s "$1" ] && tail -n "${2:-8}" "$1" || echo "(empty)"; }

printf 'jules-ops status  %s\n' "$(date -u '+%d/%m/%Y %H:%M:%S UTC')"

sec "cron"
crontab -l 2>/dev/null | grep 'jules-' || echo "(no jules cron entries)"
sec "cron.log"        ; tail_or "${DIR}/cron.log" 12
sec "rotation"        ; tail_or "${DIR}/jules-rotate.log" 5
sec "stalled sweep"   ; tail_or "${DIR}/jules-stalled.log" 12
sec "release watch"   ; tail_or "${DIR}/jules-watch.log" 5

sec "escalated, awaiting a human answer"
if [ -s "${DIR}/stalled-seen.json" ]; then
  jq -r 'to_entries[] | select(.value.escalated == true)
         | "\(.key)  idle_since=\(.value.updated)  attempts=\(.value.attempts)"' \
    "${DIR}/stalled-seen.json" | grep . || echo "(none)"
else
  echo "(no state yet)"
fi

sec "sessions by state"
sessions="$("${DIR}/jules.sh" ls 100)"
cut -f2 <<<"$sessions" | sort | uniq -c | sort -rn | awk '{printf "  %s %s\n",$1,$2}'

sec "sessions not finished"
awk -F'\t' '$2 != "COMPLETED" && $2 != "FAILED" {printf "  %-22s %-24s %s\n",$2,$3,substr($4,1,44)}' \
  <<<"$sessions" | grep . || echo "  (none)"

sec "open Jules pull requests"
"${DIR}/jules-prs.sh" list

sec "rotation position"
printf '  cursor=%s  next=%s\n' \
  "$(cat "${DIR}/rotate-cursor" 2>/dev/null || echo 0)" \
  "$(grep -vE '^[[:space:]]*(#|$)' "${DIR}/repos.priority" \
     | sed -n "$((($(cat "${DIR}/rotate-cursor" 2>/dev/null || echo 0) % $(grep -cvE '^[[:space:]]*(#|$)' "${DIR}/repos.priority")) + 1))p")"
