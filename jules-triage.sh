#!/usr/bin/env bash
# Read-only triage of stalled Jules sessions: for every session waiting on a
# human or failed, pull its last activity and write one report you can answer
# in a single pass. Changes nothing in Jules.
set -euo pipefail

DIR="/var/lib/nova-mcp/work/jules-ops"
HOURS="${JULES_STALL_HOURS:-4}"
OUT="${JULES_TRIAGE_OUT:-${DIR}/triage-$(date -u '+%Y%m%d').md}"
STALL_STATES='AWAITING_USER_FEEDBACK AWAITING_PLAN_APPROVAL FAILED'

cutoff="$(date -u -d "-${HOURS} hours" '+%Y-%m-%dT%H:%M:%SZ')"
sessions="$("${DIR}/jules.sh" ls 100)"

{
  printf '# Jules triage — %s\n\n' "$(date -u '+%d/%m/%Y %H:%M:%S UTC')"
  printf 'Sessions in %s, idle longer than %sh.\n' "${STALL_STATES// /, }" "$HOURS"
} >"$OUT"

n=0
while IFS=$'\t' read -r id state updated title; do
  [ -n "${id:-}" ] || continue
  case " ${STALL_STATES} " in *" ${state} "*) ;; *) continue ;; esac
  [[ "$updated" < "$cutoff" ]] || continue
  n=$((n + 1))
  last="$("${DIR}/jules.sh" activities "$id" \
    | jq -r '(.activities // []) | last
             | (.agentMessaged.agentMessage
                // .userMessaged.userMessage
                // .planGenerated.plan
                // (. | tostring))' \
    | tr '\n' ' ' | tr -d '\000-\010\013\014\016-\037\177' | cut -c1-600)"
  {
    printf '\n## %s. %s — %s\n\n' "$n" "$state" "$title"
    printf -- '- id: `%s`\n- idle since: %s\n- last activity: %s\n' "$id" "$updated" "$last"
  } >>"$OUT"
done <<<"$sessions"

printf '\n_%s session(s) reported._\n' "$n" >>"$OUT"
printf '%s\n' "$OUT"
