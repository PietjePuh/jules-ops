#!/usr/bin/env bash
# Start Jules sessions on every eligible repo in repos.allow (file order =
# rotation order, fallback repos last), rotating the three agent personas, up
# to the account's daily session-creation quota. Skips a repo that already has
# a live or stalled session so work never piles up behind an unanswered
# question, and skips a repo over the open-PR cap so recurring agents don't
# stack duplicate work on top of a review backlog.
#
# Was: start at most one session per invocation ("nightly"). Changed
# 25/09/2026 (Tim: "make sure jules gets 100 tasks every day... use jules
# more") to walk the whole rotation each pass and consume as much of the daily
# quota as eligible repos allow, since the real limit is the account's 100
# sessions/day, not one-per-day self-throttling. jules-autopilot.timer calling
# this every 30 min now does the saturating; this script just stops safely
# short of the account cap so a chatty pass never trips a Jules-side lockout.
#
# 27/09/2026: repos.priority and repos.pinned removed (Tim) — repos.allow is
# now the single list. Pinning is moot when every pass walks every eligible
# repo; there is nothing to starve.
set -euo pipefail

DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
. "${DIR}/notify.sh"

# Lock: 25/09/2026 incident — a manual run overlapped a timer-triggered run
# and started the SAME repo/persona pair twice (zero-trust, TI, toolbelt-next,
# nova-mcp, N8N---SOC-Workflows all doubled) because both processes read the
# "busy" snapshot before either had written anything back. flock is
# process-local only (doesn't cross fastbelt/nova), but cross-host double
# starts are still caught by the live daily-quota count reading the API, and
# a genuine same-repo double-start is caught by busy_repos on the NEXT pass —
# this lock closes the same-host same-second race, which was the actual cause.
LOCK="${JULES_ROTATE_LOCK:-${DIR}/.jules-rotate.lock}"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "jules-rotate: another instance is already running on this host, exiting" >&2
  exit 0
fi

OWNER="${JULES_OWNER:-PietjePuh}"
CURSOR="${JULES_ROTATE_CURSOR:-${DIR}/rotate-cursor}"
PERSONA_CURSOR="${JULES_PERSONA_CURSOR:-${DIR}/persona-cursor}"
LOG="${DIR}/jules-rotate.log"
PERSONAS=(sentinel palette bolt)
BUSY='QUEUED PLANNING IN_PROGRESS AWAITING_USER_FEEDBACK AWAITING_PLAN_APPROVAL PAUSED'
# Account-wide daily cap is 100 session-creations/day. Stop short of it so a
# concurrent host or a manual session never overshoots into a 429/lockout.
DAILY_LIMIT="${JULES_DAILY_LIMIT:-100}"
DAILY_SAFETY_MARGIN="${JULES_DAILY_SAFETY_MARGIN:-5}"
MAX_OPEN_PRS="${JULES_MAX_OPEN_PRS:-5}"

stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"
mapfile -t REPOS < <(grep -vE '^\s*(#|$)' "${DIR}/repos.allow")
[ "${#REPOS[@]}" -gt 0 ] || { echo "jules-rotate: repos.allow is empty" >&2; exit 2; }

i="$(cat "$CURSOR" 2>/dev/null || echo 0)"
p="$(cat "$PERSONA_CURSOR" 2>/dev/null || echo 0)"
sessions="$("${DIR}/jules.sh" ls 500)"

# Live count of sessions created today (UTC), whoever/whatever started them —
# this is the real Jules-side quota, so read it from the API every pass rather
# than trusting a local counter that could drift across hosts.
today="$(date -u '+%Y-%m-%d')"
used_today="$(awk -F'\t' -v d="$today" '$3 ~ ("^" d)' <<<"$sessions" | wc -l)"
budget=$((DAILY_LIMIT - DAILY_SAFETY_MARGIN - used_today))
if [ "$budget" -le 0 ]; then
  printf '[%s] daily quota reached: %s sessions created today (limit %s, margin %s) — nothing started\n' \
    "$stamp" "$used_today" "$DAILY_LIMIT" "$DAILY_SAFETY_MARGIN" >>"$LOG"
  notify ":chart_with_upwards_trend: jules-rotate: daily quota reached (${used_today}/${DAILY_LIMIT}, ${stamp}) — resets at UTC midnight"
  printf 'started=0 skipped=0 failed=0 budget_left=0 quota_reached=1\n'
  exit 0
fi

# Repos that already have a live or stalled session — never stack a second one.
busy_repos="$(while IFS=$'\t' read -r id state _ _; do
  case " ${BUSY} " in *" ${state} "*) ;; *) continue ;; esac
  "${DIR}/jules.sh" get "$id" | jq -r '.sourceContext.source // empty'
done <<<"$sessions" | sed 's#.*/##' | sort -u)"

# A repo with unmerged Jules PRs does not need more Jules PRs. Recurring agents
# open work in isolation and never look at what is already outstanding, which is
# how one repo ends up with 62 near-identical PRs. Backpressure, not de-duping
# after the fact.
open_prs() {
  "${DIR}/jules-prs.sh" list "$1" 2>/dev/null | awk '{for(f=1;f<=NF;f++) if ($f ~ /^open=/) {sub(/^open=/,"",$f); print $f}}'
}

# TIM-297 (06/10/2026): backpressure (open_prs, above) caps how much unreviewed
# work piles up, but it never stopped a repo from getting the SAME topic over
# and over once PRs drained below the ceiling -- live proof: rork-cityspot-
# finder got 87 "Palette" session starts for only 33 resulting PRs (any
# state), the rest churned re-discovering accessibility/focus-state issues
# already fixed in an earlier pass, because the prompt carries zero memory of
# prior sessions. Pull the persona's recent PR titles on this repo (any
# state, cheap read-only gh call) and hand them to the agent as "already
# addressed" context so it is steered toward a genuinely different file or
# issue category instead of re-finding the same class of fix.
recent_topics() {
  local repo="$1" persona="$2" cap
  cap="$(tr '[:lower:]' '[:upper:]' <<<"${persona:0:1}")${persona:1}"
  gh pr list --repo "${OWNER}/${repo}" --state all --search "author:app/google-labs-jules" \
    --limit 60 --json title 2>/dev/null \
    | jq -r --arg p "$cap" '.[] | select(.title | test($p)) | .title' \
    | head -12
}

started=()
skipped=''
failed=''
done_repos=''

# try_start <repo> <pr_ceiling> -> 0 if a session was started, 1 otherwise.
# Advances the shared persona cursor and daily budget on success.
try_start() {
  local repo="$1" ceiling="$2" n_prs persona prompt out avoid
  if grep -qxF "$repo" <<<"$busy_repos" || grep -qxF "$repo" <<<"$done_repos"; then
    skipped+="${repo}(session) "
    return 1
  fi
  n_prs="$(open_prs "$repo")"
  if [ -n "${n_prs:-}" ] && [ "$n_prs" -ge "$ceiling" ]; then
    skipped+="${repo}(${n_prs}prs) "
    return 1
  fi

  persona="${PERSONAS[$((p % ${#PERSONAS[@]}))]}"
  p=$((p + 1))
  prompt="$(cat "${DIR}/prompts/${persona}.md")"

  avoid="$(recent_topics "$repo" "$persona")"
  if [ -n "$avoid" ]; then
    prompt="${prompt}

## Already addressed on this repo in earlier sessions — do NOT repeat or pick a near-duplicate of these (same file, same category of issue):
${avoid}

Pick a genuinely different file or a different category of issue. If nothing new qualifies, stop without opening a pull request."
  fi

  if out="$("${DIR}/jules.sh" new "${OWNER}/${repo}" "$prompt" \
            --title "${persona^}: ${repo}" --auto-pr 2>&1)"; then
    printf '[%s] started %s on %s -> %s\n' "$stamp" "$persona" "$repo" "$out" >>"$LOG"
    started+=("${persona}:${repo}")
    done_repos="$(printf '%s\n%s\n' "$done_repos" "$repo")"
    budget=$((budget - 1))
    return 0
  fi
  printf '[%s] FAILED to start %s on %s\n%s\n' "$stamp" "$persona" "$repo" "$out" >>"$LOG"
  failed+="${repo} "
  return 1
}

# --- round-robin repos.allow with the day's remaining budget ---
attempts=0
while [ "$budget" -gt 0 ] && [ "$attempts" -lt "${#REPOS[@]}" ]; do
  repo="${REPOS[$((i % ${#REPOS[@]}))]}"
  i=$((i + 1))
  attempts=$((attempts + 1))
  try_start "$repo" "$MAX_OPEN_PRS" || true
done
printf '%s\n' "$i" >"$CURSOR"
printf '%s\n' "$p" >"$PERSONA_CURSOR"

if [ "${#started[@]}" -eq 0 ] && [ -z "$failed" ]; then
  printf '[%s] nothing started; skipped: %s\n' "$stamp" "$skipped" >>"$LOG"
  notify ":no_entry: jules-rotate started nothing (${stamp})
every repo is busy or over its open-PR limit:
  ${skipped}"
  printf 'started=0 skipped=%s failed=0 budget_left=%s\n' \
    "$(wc -w <<<"$skipped")" "$budget"
  exit 0
fi

if [ "${#started[@]}" -gt 0 ]; then
  notify ":rocket: Jules started ${#started[@]} session(s) (${stamp}), ${budget}+${DAILY_SAFETY_MARGIN} of ${DAILY_LIMIT} daily budget left:
$(printf '  %s\n' "${started[@]}")
skipped: ${skipped:-none}"
fi
# Single machine-readable result line on stdout — the caller-facing contract
# (autopilot log capture, MCP wrapper). Prose stays in the log and Slack.
printf 'started=%s skipped=%s failed=%s budget_left=%s\n' \
  "${#started[@]}" "$(wc -w <<<"$skipped")" "$(wc -w <<<"$failed")" "$budget"
if [ -n "$failed" ]; then
  notify ":rotating_light: jules-rotate: failed to start on: ${failed}(${stamp})"
  exit 1
fi
