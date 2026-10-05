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
#        JULES_STALL_MAX_ACTIONS  max candidates acted on per pass, default 20
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

# Persist seen-state incrementally (TIM-289): the pre-fix loop wrote $SEEN only
# AFTER the whole walk, so a pass killed by the unit timeout (TimeoutStartSec=
# 600) lost all progress and every 15-min pass re-walked the same backlog
# forever — stalled-seen.json mtime sat at 27/09 while passes kept dying.
# Atomic tmp+mv snapshot after each state-changing iteration survives a TERM;
# the final full write below stays as the loop-completed correction.
persist_seed() {
  printf '%s\n' "$next_json" >"${SEEN}.tmp" && mv -f "${SEEN}.tmp" "$SEEN"
}

stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"
cutoff="$(date -u -d "-${HOURS} hours" '+%Y-%m-%dT%H:%M:%SZ')"

# Single-flight guard: the 15-min timer and a Dispatch heartbeat can fire the
# sweep in the same minute (25/09 20:45-20:49Z saw three overlapping passes);
# double nudges burn Jules quota and corrupt seen/attempts state. Fail-closed.
exec 9>"${DIR}/.jules-stalled.lock"
flock -n 9 || exit 0

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
next_json="$prev_json"
held=''
acted='' ; escalated='' ; failed='' ; n_acted=0

# Per-pass action cap (TIM-289): bound each pass to a slice of the backlog so
# a pass fits the unit timeout even against a slow API. Capped-out candidates
# stay under-cutoff and surface on the next pass.
MAX_ACTIONS="${JULES_STALL_MAX_ACTIONS:-20}"

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
    persist_seed
    continue
  fi

  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    [ "$(jq -r '.escalated // false' <<<"$prev")" = true ] \
      || escalated+="  ${state}  ${id}  ${title}"$'\n'
    next_json="$(jq -c --arg i "$id" --arg u "$updated" --argjson a "$attempts" \
      '.[$i] = {updated: $u, attempts: $a, escalated: true}' <<<"$next_json")"
    persist_seed
    continue
  fi

  # Per-pass cap (TIM-289): once MAX_ACTIONS candidates were acted on this
  # pass, leave the rest untouched (no wake, no repo lookup, attempts
  # unchanged) so they surface on the next pass. The check sits BEFORE
  # session_repo() on purpose: a capped-out candidate must not cost an API
  # round-trip. Live proof 05/10: the 06:40Z boot pass fetched repos for
  # ~190 capped-out candidates (~3s each) and still hit the 600s guillotine
  # with only ~200 of the ~450-entry backlog cached. The merge preserves
  # woken/escalated/repo already on the entry; repo is fetched only for
  # candidates actually acted on or held this pass.
  if [ "$n_acted" -ge "$MAX_ACTIONS" ]; then
    next_json="$(jq -c --arg i "$id" --arg u "$updated" --argjson a "$attempts" \
      '.[$i] = ((.[$i] // {}) + {updated: $u, attempts: $a})' <<<"$next_json")"
    persist_seed
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
    persist_seed
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
  persist_seed
done <<<"$sessions"

printf '%s\n' "$next_json" >"$SEEN"

[ -n "${acted}${escalated}${failed}${held}" ] || {
  printf '[%s] nothing stalled beyond %sh\n' "$stamp" "$HOURS" >>"$LOG"
  printf 'nudged=0 escalated=0 failed=0\n'
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
# Single machine-readable result line on stdout — the caller-facing contract
# (autopilot log capture, MCP wrapper). Detail lives in the log and Slack.
printf 'nudged=%s escalated=%s failed=%s\n' \
  "$n_acted" "$(grep -c . <<<"$escalated" || true)" "$(grep -c . <<<"$failed" || true)"
