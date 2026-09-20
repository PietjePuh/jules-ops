#!/usr/bin/env bash
# Nightly: start one Jules session on the next repo in repos.priority, rotating
# the three agent personas. Skips a repo that already has a live or stalled
# session so work never piles up behind an unanswered question.
set -euo pipefail

DIR="/var/lib/nova-mcp/work/jules-ops"
# shellcheck source=/dev/null
. "${DIR}/notify.sh"

OWNER="${JULES_OWNER:-PietjePuh}"
CURSOR="${JULES_ROTATE_CURSOR:-${DIR}/rotate-cursor}"
LOG="${DIR}/jules-rotate.log"
PERSONAS=(sentinel palette bolt)
BUSY='QUEUED PLANNING IN_PROGRESS AWAITING_USER_FEEDBACK AWAITING_PLAN_APPROVAL PAUSED'

stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"
mapfile -t REPOS < <(grep -vE '^\s*(#|$)' "${DIR}/repos.priority")
[ "${#REPOS[@]}" -gt 0 ] || { echo "jules-rotate: repos.priority is empty" >&2; exit 2; }

i="$(cat "$CURSOR" 2>/dev/null || echo 0)"
sessions="$("${DIR}/jules.sh" ls 100)"

# Repos that already have a live or stalled session — never stack a second one.
busy_repos="$(while IFS=$'\t' read -r id state _ _; do
  case " ${BUSY} " in *" ${state} "*) ;; *) continue ;; esac
  "${DIR}/jules.sh" get "$id" | jq -r '.sourceContext.source // empty'
done <<<"$sessions" | sed 's#.*/##' | sort -u)"

picked=''
for _ in "${REPOS[@]}"; do
  repo="${REPOS[$((i % ${#REPOS[@]}))]}"
  i=$((i + 1))
  grep -qxF "$repo" <<<"$busy_repos" || { picked="$repo"; break; }
done
printf '%s\n' "$i" >"$CURSOR"

if [ -z "$picked" ]; then
  printf '[%s] every repo busy, nothing started\n' "$stamp" >>"$LOG"
  exit 0
fi

persona="${PERSONAS[$(( (i - 1) % ${#PERSONAS[@]} ))]}"
prompt="$(cat "${DIR}/prompts/${persona}.md")"

if out="$("${DIR}/jules.sh" new "${OWNER}/${picked}" "$prompt" \
          --title "${persona^}: ${picked}" --auto-pr 2>&1)"; then
  printf '[%s] started %s on %s -> %s\n' "$stamp" "$persona" "$picked" "$out" >>"$LOG"
  notify ":rocket: Jules ${persona} started on ${OWNER}/${picked} (${stamp})
${out}"
else
  printf '[%s] FAILED to start %s on %s\n%s\n' "$stamp" "$persona" "$picked" "$out" >>"$LOG"
  notify ":rotating_light: jules-rotate could not start ${persona} on ${picked} (${stamp})
${out}"
  exit 1
fi
