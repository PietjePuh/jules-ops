#!/usr/bin/env bash
# Orchestrator for stuck Jules sessions.
#
# Every run: find sessions waiting on a human or failed, idle beyond
# JULES_STALL_HOURS, and act instead of only reporting.
#   AWAITING_PLAN_APPROVAL  -> approve the plan
#   AWAITING_USER_FEEDBACK  -> tell the agent to decide and ship
#   FAILED                  -> report once, no action possible
# A session gets at most two attempts at the same updateTime; after that it is
# escalated to Slack once and left alone until it actually moves.
#
#   env: JULES_STALL_HOURS      idle threshold, default 4
#        JULES_DRYRUN_ACTIONS=1 print actions instead of performing them
#        JULES_NOTIFY_DRYRUN=1  print the Slack payload instead of posting
#        JULES_SESSIONS_SRC     read the session TSV from this file (testing)
set -euo pipefail

DIR="/var/lib/nova-mcp/work/jules-ops"
# shellcheck source=/dev/null
. "${DIR}/notify.sh"

HOURS="${JULES_STALL_HOURS:-4}"
SEEN="${JULES_STALL_SEEN:-${DIR}/stalled-seen.json}"
LOG="${DIR}/jules-stalled.log"
MAX_ATTEMPTS=2
UNBLOCK_MSG='Pick the single highest-value item from the candidates you listed and implement it now. Do not ask any further questions and do not present options. Run the repository lint and test commands, then open a pull request. If none of the candidates qualifies, stop without opening a pull request.'

stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"
cutoff="$(date -u -d "-${HOURS} hours" '+%Y-%m-%dT%H:%M:%SZ')"

if [ -n "${JULES_SESSIONS_SRC:-}" ]; then
  sessions="$(cat "${JULES_SESSIONS_SRC}")"
else
  err="$(mktemp)"
  if ! sessions="$("${DIR}/jules.sh" ls 100 2>"$err")"; then
    msg="$(cat "$err")"; rm -f "$err"
    printf '[%s] FAILED to list sessions\n%s\n' "$stamp" "$msg" >>"$LOG"
    notify ":rotating_light: jules-stalled could not list sessions on nova (${stamp})
${msg}"
    exit 1
  fi
  rm -f "$err"
fi

act() { # act <verb> <id> ; verb = approve | unblock
  if [ "${JULES_DRYRUN_ACTIONS:-0}" = "1" ]; then
    printf 'would %s %s\n' "$1" "$2"
    return 0
  fi
  case "$1" in
    approve) "${DIR}/jules.sh" approve "$2" >/dev/null ;;
    unblock) "${DIR}/jules.sh" msg "$2" "$UNBLOCK_MSG" >/dev/null ;;
  esac
}

prev_json="$(cat "$SEEN" 2>/dev/null || echo '{}')"
next_json='{}'
acted='' ; escalated='' ; failed='' ; n_acted=0

while IFS=$'\t' read -r id state updated title; do
  [ -n "${id:-}" ] || continue
  case "$state" in AWAITING_USER_FEEDBACK|AWAITING_PLAN_APPROVAL|FAILED) ;; *) continue ;; esac
  [[ "$updated" < "$cutoff" ]] || continue

  prev="$(jq -c --arg i "$id" '.[$i] // {}' <<<"$prev_json")"
  prev_updated="$(jq -r '.updated // ""' <<<"$prev")"
  attempts="$(jq -r '.attempts // 0' <<<"$prev")"
  [ "$prev_updated" = "$updated" ] || attempts=0   # session moved, start over

  if [ "$state" = FAILED ]; then
    [ "$prev_updated" = "$updated" ] || failed+="  FAILED  ${id}  ${title}"$'\n'
    next_json="$(jq -c --arg i "$id" --arg u "$updated" \
      '.[$i] = {updated: $u, attempts: 0}' <<<"$next_json")"
    continue
  fi

  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    [ "$(jq -r '.escalated // false' <<<"$prev")" = true ] \
      || escalated+="  ${state}  ${id}  ${title}"$'\n'
    next_json="$(jq -c --arg i "$id" --arg u "$updated" --argjson a "$attempts" \
      '.[$i] = {updated: $u, attempts: $a, escalated: true}' <<<"$next_json")"
    continue
  fi

  verb=unblock
  [ "$state" != AWAITING_PLAN_APPROVAL ] || verb=approve
  if act "$verb" "$id"; then
    attempts=$((attempts + 1)); n_acted=$((n_acted + 1))
    [ "$n_acted" -gt 10 ] || acted+="  ${verb}  ${id}  ${title}"$'\n'
  else
    escalated+="  ${state} (${verb} failed)  ${id}  ${title}"$'\n'
  fi
  next_json="$(jq -c --arg i "$id" --arg u "$updated" --argjson a "$attempts" \
    '.[$i] = {updated: $u, attempts: $a}' <<<"$next_json")"
done <<<"$sessions"

printf '%s\n' "$next_json" >"$SEEN"

[ -n "${acted}${escalated}${failed}" ] || {
  printf '[%s] nothing stalled beyond %sh\n' "$stamp" "$HOURS" >>"$LOG"
  exit 0
}

body=''
[ -z "$acted" ]     || body+=":arrow_forward: nudged ${n_acted}:"$'\n'"${acted}"
[ "$n_acted" -le 10 ] || body+="  ... and $((n_acted - 10)) more"$'\n'
[ -z "$escalated" ] || body+=":raised_hand: needs you, ${MAX_ATTEMPTS} attempts spent:"$'\n'"${escalated}"
[ -z "$failed" ]    || body+=":x: failed sessions:"$'\n'"${failed}"

printf '[%s]\n%s' "$stamp" "$body" >>"$LOG"
notify ":hourglass_flowing_sand: Jules stalled-session sweep (${stamp}):
${body}"
