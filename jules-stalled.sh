#!/usr/bin/env bash
# Orchestrator for stuck Jules sessions.
#
# Every run: find sessions waiting on a human or failed, idle beyond
# JULES_STALL_HOURS, and act instead of only reporting.
#   AWAITING_PLAN_APPROVAL  -> approve the plan
#   AWAITING_USER_FEEDBACK  -> tell the agent to decide and ship
#   FAILED                  -> report once, no action possible
#   COMPLETED (rare)        -> one wake if it holds an unshipped diff (TIM-95):
#                              a session halted by a hold instruction ("do NOT
#                              open a PR yet") can reach COMPLETED with finished
#                              work stranded, and no other state ever revisits
#                              it. Woken once, never re-woken.
# A session gets at most two attempts at the same updateTime; after that it is
# escalated to Slack once and left alone until it actually moves.
#
#   env: JULES_STALL_HOURS      idle threshold, default 4
#        JULES_DRYRUN_ACTIONS=1 print actions instead of performing them
#        JULES_NOTIFY_DRYRUN=1  print the Slack payload instead of posting
#        JULES_SESSIONS_SRC     read the session TSV from this file (testing)
set -euo pipefail

DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
. "${DIR}/notify.sh"

HOURS="${JULES_STALL_HOURS:-1}"
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
  if ! sessions="$("${DIR}/jules.sh" ls 500 2>"$err")"; then
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

# Rotation refuses to START NEW work on a repo that already has a pile of
# open PRs. A nudge to an ALREADY-RUNNING session cannot create a 4th PR on
# top of the cap (the session's PR, if any, already exists) -- gating nudges
# too only freezes work already in flight for no backpressure benefit, so
# nudges are exempt (Tim, 2026-09-25, TIM-46). New-session starts still
# respect the cap. Default mirrors rotation's JULES_MAX_OPEN_PRS (5); the
# old default of 3 here created a phantom "3-open-PR cap" operators cited
# when halting sessions.
MAX_OPEN_PRS="${JULES_MAX_OPEN_PRS:-5}"
over_limit="$("${DIR}/jules-prs.sh" list 2>/dev/null \
  | awk -v m="$MAX_OPEN_PRS" '{n=$2; sub(/^open=/,"",n); if (n+0 >= m) print $1}')"

# repo for a session, cached in the state file so a backlog is not re-fetched
session_repo() {
  local id="$1" cached
  cached="$(jq -r --arg i "$id" '.[$i].repo // empty' <<<"$prev_json")"
  if [ -n "$cached" ]; then printf '%s' "$cached"; return 0; fi
  "${DIR}/jules.sh" get "$id" | jq -r '.sourceContext.source // empty' | sed 's#.*/##'
}

prev_json="$(cat "$SEEN" 2>/dev/null || echo '{}')"
next_json='{}'
held=''
acted='' ; escalated='' ; failed='' ; n_acted=0

while IFS=$'\t' read -r id state updated title; do
  [ -n "${id:-}" ] || continue
  case "$state" in AWAITING_USER_FEEDBACK|AWAITING_PLAN_APPROVAL|FAILED|COMPLETED) ;; *) continue ;; esac
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

  repo="$(session_repo "$id")"
  # NOTE: nudging/approving an ALREADY-RUNNING stalled session is exempt from
  # MAX_OPEN_PRS (Tim, 2026-09-25, TIM-46) — the session's own PR, if any,
  # already exists, so holding it here only freezes in-flight work with no
  # backpressure benefit. over_limit is still computed above and still
  # gates NEW session starts in jules-rotate.sh / jules-autopilot.sh.

  verb=unblock
  [ "$state" != AWAITING_PLAN_APPROVAL ] || verb=approve
  if [ "$state" = COMPLETED ] \
     && [ "$(jq -r '.woken // false' <<<"$prev")" = "true" ]; then
    # Wake a completed session at most once ever: a completed session treats a
    # new message as a NEW task, so re-waking on every pass would turn this
    # sweep into a work generator. The woken flag is written by the tail state
    # update below and deliberately survives updateTime changes.
    next_json="$(jq -c --arg i "$id" --arg u "$updated" \
      --arg r "$(jq -r '.repo // ""' <<<"$prev")" --argjson a "$attempts" \
      '.[$i] = {updated: $u, attempts: $a, repo: $r, woken: true}' <<<"$next_json")"
    continue
  fi
  woken=false
  if act "$verb" "$id"; then
    attempts=$((attempts + 1)); n_acted=$((n_acted + 1))
    [ "$n_acted" -gt 10 ] || acted+="  ${verb}  ${id}  ${title}"$'\n'
    # a COMPLETED session is woken at most once: mark it only after a
    # successful send, so a failed wake retries on the next pass
    [ "$state" != COMPLETED ] || woken=true
  else
    escalated+="  ${state} (${verb} failed)  ${id}  ${title}"$'\n'
  fi
  next_json="$(jq -c --arg i "$id" --arg u "$updated" --arg r "${repo:-}" --argjson a "$attempts" --argjson w "$woken" \
    '.[$i] = {updated: $u, attempts: $a, repo: $r} + (if $w then {woken: true} else {} end)' <<<"$next_json")"
done <<<"$sessions"

printf '%s\n' "$next_json" >"$SEEN"

[ -n "${acted}${escalated}${failed}${held}" ] || {
  printf '[%s] nothing stalled beyond %sh\n' "$stamp" "$HOURS" >>"$LOG"
  exit 0
}

body=''
[ -z "$acted" ]     || body+=":arrow_forward: nudged ${n_acted}:"$'\n'"${acted}"
[ "$n_acted" -le 10 ] || body+="  ... and $((n_acted - 10)) more"$'\n'
[ -z "$escalated" ] || body+=":raised_hand: needs you, ${MAX_ATTEMPTS} attempts spent:"$'\n'"${escalated}"
[ -z "$failed" ]    || body+=":x: failed sessions:"$'\n'"${failed}"
[ -z "$held" ]      || body+=":pause_button: held, repo already over ${MAX_OPEN_PRS} open PRs:"$'\n'"$(head -10 <<<"$held")"

printf '[%s]\n%s' "$stamp" "$body" >>"$LOG"
notify ":hourglass_flowing_sand: Jules stalled-session sweep (${stamp}):
${body}"
