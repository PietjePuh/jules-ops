#!/usr/bin/env bash
# Alert on Jules sessions that are waiting on a human, or have failed, and have
# not moved for JULES_STALL_HOURS. Re-alerts only when a session's updateTime
# changes, so a session parked for days is reported once.
set -euo pipefail

DIR="/var/lib/nova-mcp/work/jules-ops"
# shellcheck source=/dev/null
. "${DIR}/notify.sh"

HOURS="${JULES_STALL_HOURS:-4}"
SEEN="${JULES_STALL_SEEN:-${DIR}/stalled-seen.json}"
LOG="${DIR}/jules-stalled.log"
STALL_STATES='AWAITING_USER_FEEDBACK AWAITING_PLAN_APPROVAL FAILED'

stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"
cutoff="$(date -u -d "-${HOURS} hours" '+%Y-%m-%dT%H:%M:%SZ')"
err="$(mktemp)"

if ! sessions="$("${DIR}/jules.sh" ls 100 2>"$err")"; then
  msg="$(cat "$err")"; rm -f "$err"
  printf '[%s] FAILED\n%s\n' "$stamp" "$msg" >>"$LOG"
  notify ":rotating_light: jules-stalled could not list sessions on nova (${stamp})
${msg}"
  exit 1
fi
rm -f "$err"

current='{}'
report=''
count=0
prev_json="$(cat "$SEEN" 2>/dev/null || echo '{}')"
while IFS=$'\t' read -r id state updated title; do
  [ -n "${id:-}" ] || continue
  case " ${STALL_STATES} " in *" ${state} "*) ;; *) continue ;; esac
  [[ "$updated" < "$cutoff" ]] || continue
  current="$(jq -c --arg i "$id" --arg u "$updated" '.[$i] = $u' <<<"$current")"
  prev="$(jq -r --arg i "$id" '.[$i] // ""' <<<"$prev_json")"
  [ "$prev" != "$updated" ] || continue
  count=$((count + 1))
  if [ "$count" -le 10 ]; then
    report+="  ${state}  ${updated}  ${id}  ${title}"$'\n'
  fi
done <<<"$sessions"

printf '%s\n' "$current" >"$SEEN"

if [ -z "$report" ]; then
  printf '[%s] nothing stalled beyond %sh\n' "$stamp" "$HOURS" >>"$LOG"
  exit 0
fi

printf '[%s] stalled\n%s' "$stamp" "$report" >>"$LOG"
more=''
[ "$count" -le 10 ] || more="  ... and $((count - 10)) more, see ${LOG}"$'\n'
notify ":hourglass_flowing_sand: ${count} Jules session(s) stalled >${HOURS}h (${stamp}):
${report}${more}"
