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
# Answers are composed per-session by jules-answer.sh (reads the agent's
# actual question: requirements -> issue body, credentials -> escalate,
# else contextual autonomy). The canned UNBLOCK_MSG was retired 2026-10-05:
# it ignored what the agent asked and sessions stalled anyway.

# Scope guard (TIM-291): the sweep's candidate list is the WHOLE Jules account
# session list, but repos.allow (Tim, 25/09) narrows Jules to omarchy-
# toolbelt, Toolbelt, airplane-sole + rork-cityspot-finder as fallback. The
# rotator is fail-closed on that list; the stall sweep historically was not,
# and woke sessions on agentforge/AI/Main/BackgroundRemoval. scope_allow()
# prints the in-scope repo names (verbatim bare names, like jules.sh) or '*'
# when the guard is disabled via JULES_SCOPE_OFF=1. An EMPTY output is
# meaningful and fail-closed: with no verifiable allowlist every candidate
# classifies out-of-scope and is skipped+recorded, never acted on.
scope_allow() {
  "${DIR}/jules-scope-allow.sh"
}
SCOPE_OFF=0
if [ "$(scope_allow | head -1)" = "*" ]; then
  SCOPE_OFF=1
  scope_set='*'
else
  scope_set="$(scope_allow | grep -v '^$' || true)"
fi

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
  # Returns 0 acted, 3 stale-skip (unblock only), nonzero failure.
  # jules-answer's stdout — what was actually sent to the session — lands
  # in $answer_out for the acted log line: real interaction must be
  # auditable in the log, not swallowed by /dev/null (Tim, 2026-10-05).
  answer_out=''
  if [ "${JULES_DRYRUN_ACTIONS:-0}" = "1" ]; then
    printf 'would %s %s\n' "$1" "$2"
    return 0
  fi
  case "$1" in
    approve) "${DIR}/jules.sh" approve "$2" >/dev/null ;;
    unblock)
      answer_out="$("${DIR}/jules-answer.sh" "$2" 2>/dev/null)" && return 0
      rc=$?
      [ "$rc" -eq 3 ] || return 1
      answer_out='stale (state moved on, no message sent)'
      return 3
      ;;
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
held=''; acted=''; escalated=''; failed=''
n_acted=0; n_skipped=0; skipped_repos=''

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
  prev_state="$(jq -r '.state // ""' <<<"$prev")"
  attempts="$(jq -r '.attempts // 0' <<<"$prev")"
  # TIM-296 (06/10/2026): was keyed on updateTime ([ "$prev_updated" = "$updated" ]),
  # but OUR OWN unblock message bumps the session's updateTime every pass, so
  # attempts reset to 0 before ever reaching MAX_ATTEMPTS -- a session stuck in
  # the same stalled state got the identical canned nudge forever and never
  # escalated (live proof 05/10: session 2814833911976743175 nudged at 17:07
  # and again at 19:07, two hours apart, both "quoted question -> autonomy",
  # attempts never ticking past 1). Key on state instead: a session that
  # cycles through RUNNING is filtered out of candidacy while running (case
  # statement above), so reappearing here still AWAITING_* means it is still
  # the same unresolved ask, not a fresh one.
  [ "$prev_state" = "$state" ] || attempts=0   # state actually changed, start over

  if [ "$state" = FAILED ]; then
    [ "$prev_updated" = "$updated" ] || failed+="  FAILED  ${id}  ${title}"$'\n'
    next_json="$(jq -c --arg i "$id" --arg u "$updated" --arg st "$state" \
      '.[$i] = {updated: $u, state: $st, attempts: 0}' <<<"$next_json")"
    persist_seed
    continue
  fi

  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    [ "$(jq -r '.escalated // false' <<<"$prev")" = true ] \
      || escalated+="  ${state}  ${id}  ${title}"$'\n'
    next_json="$(jq -c --arg i "$id" --arg u "$updated" --arg st "$state" --argjson a "$attempts" \
      '.[$i] = {updated: $u, state: $st, attempts: $a, escalated: true}' <<<"$next_json")"
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
    next_json="$(jq -c --arg i "$id" --arg u "$updated" --arg st "$state" --argjson a "$attempts" \
      '.[$i] = ((.[$i] // {}) + {updated: $u, state: $st, attempts: $a})' <<<"$next_json")"
    persist_seed
    continue
  fi

  # Scope filter (TIM-291): never act on a session whose repo is outside
  # repos.allow. Placement is deliberate: AFTER the #19 cap branch (capped-out
  # candidates must not pay a repo round-trip) and BEFORE the woken-once /
  # act paths (an out-of-scope COMPLETED session must not even get its single
  # wake). A cached repo classifies with no API call; a cache miss pays one
  # session_repo() here for candidates that reach this line. The skip is
  # recorded like any other terminal disposition, and the entry keeps
  # woken/escalated so a guard disable+re-enable never re-wakes a completed
  # session the guard once skipped.
  if [ "$SCOPE_OFF" = "0" ]; then
    cached_repo="$(jq -r --arg i "$id" '.[$i].repo // ""' <<<"$prev_json")"
    if [ -n "$cached_repo" ]; then
      repo="$cached_repo"
    else
      repo="$(session_repo "$id")"
    fi
    in_scope=0
    if [ -n "$repo" ] && [ -n "$scope_set" ] \
       && grep -qxF -- "$repo" <<<"$scope_set"; then
      in_scope=1
    fi
    if [ "$in_scope" = "0" ]; then
      prev_w="$(jq -r '.woken // false' <<<"$prev")"
      prev_e="$(jq -r '.escalated // false' <<<"$prev")"
      next_json="$(jq -c --arg i "$id" --arg u "$updated" --arg st "$state" --arg r "${repo:-}" \
        --argjson a "$attempts" --argjson w "$prev_w" --argjson e "$prev_e" \
        '.[$i] = {updated: $u, state: $st, attempts: $a, repo: $r, skipped: "out_of_scope"}
                 + (if $w then {woken: true} else {} end)
                 + (if $e then {escalated: true} else {} end)' <<<"$next_json")"
      persist_seed
      n_skipped=$((n_skipped + 1))
      [ "$n_skipped" -gt 10 ] || skipped_repos+="${repo:-<unknown>}"$'\n'
      continue
    fi
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
    next_json="$(jq -c --arg i "$id" --arg u "$updated" --arg st "$state" \
      --arg r "$(jq -r '.repo // ""' <<<"$prev")" --argjson a "$attempts" \
      '.[$i] = {updated: $u, state: $st, attempts: $a, repo: $r, woken: true}' <<<"$next_json")"
    persist_seed
    continue
  fi

  woken=false
  act_rc=0
  act "$verb" "$id" || act_rc=$?
  if [ "$act_rc" -eq 3 ]; then
    # Stale snapshot: the session moved on between `jules.sh ls` and the
    # answer call, so there is no question to answer. Not a nudge, not a
    # failure: attempts stay untouched so a genuinely-waiting session
    # later still gets its full two tries (2026-10-05: live proof — the
    # 11:02Z pass "nudged" 20 sessions that had all self-resolved; every
    # answer was a silent skip, inflating nudged= to a meaningless count).
    next_json="$(jq -c --arg i "$id" --arg u "$updated" --arg st "$state" --arg r "${repo:-}" --argjson a "$attempts" \
      '.[$i] = ((.[$i] // {}) + {updated: $u, state: $st, attempts: $a, repo: $r})' <<<"$next_json")"
    persist_seed
    continue
  fi
  if [ "$act_rc" -eq 0 ]; then
    attempts=$((attempts + 1)); n_acted=$((n_acted + 1))
    [ "$n_acted" -gt 10 ] || acted+="  ${verb}  ${id}  ${title}${answer_out:+  —  ${answer_out}}"$'\n'
    # a COMPLETED session is woken at most once: mark it only after a
    # successful send, so a failed wake retries on the next pass
    [ "$state" != COMPLETED ] || woken=true
  else
    # A failed send burns an attempt too (2026-10-05): without this bump a
    # persistently failing session (API error, expired id) retried every
    # pass forever with attempts frozen at 0, never reaching the 2-strike
    # cap — silent quota burn the "needs you, 2 attempts spent" report
    # line never reflected.
    attempts=$((attempts + 1))
    escalated+="  ${state} (${verb} failed)  ${id}  ${title}"$'\n'
  fi
  next_json="$(jq -c --arg i "$id" --arg u "$updated" --arg st "$state" --arg r "${repo:-}" --argjson a "$attempts" --argjson w "$woken" \
    '.[$i] = {updated: $u, state: $st, attempts: $a, repo: $r} + (if $w then {woken: true} else {} end)' <<<"$next_json")"
  persist_seed
done <<<"$sessions"

printf '%s\n' "$next_json" >"$SEEN"

if [ "$n_skipped" -gt 0 ]; then
  uniq_repos="$(sort -u <<<"$skipped_repos" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')"
  printf '[%s] skipped %d out-of-scope candidate(s) (repos.allow filter, TIM-291): %s\n' \
    "$stamp" "$n_skipped" "$uniq_repos" >>"$LOG"
fi

[ -n "${acted}${escalated}${failed}${held}" ] || {
  printf '[%s] nothing stalled beyond %sh\n' "$stamp" "$HOURS" >>"$LOG"
  printf 'nudged=0 escalated=0 failed=0 skipped=%s\n' "$n_skipped"
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
printf 'nudged=%s escalated=%s failed=%s skipped=%s\n' \
  "$n_acted" "$(grep -c . <<<"$escalated" || true)" "$(grep -c . <<<"$failed" || true)" \
  "$n_skipped"
