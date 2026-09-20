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

# A repo with unmerged Jules PRs does not need more Jules PRs. Recurring agents
# open work in isolation and never look at what is already outstanding, which is
# how one repo ends up with 62 near-identical PRs. Backpressure, not de-duping
# after the fact.
MAX_OPEN_PRS="${JULES_MAX_OPEN_PRS:-3}"
open_prs() {
  "${DIR}/jules-prs.sh" list "$1" 2>/dev/null | awk '{for(f=1;f<=NF;f++) if ($f ~ /^open=/) {sub(/^open=/,"",$f); print $f}}'
}

picked=''
skipped=''
for _ in "${REPOS[@]}"; do
  repo="${REPOS[$((i % ${#REPOS[@]}))]}"
  i=$((i + 1))
  if grep -qxF "$repo" <<<"$busy_repos"; then
    skipped+="${repo}(session) "
    continue
  fi
  n_prs="$(open_prs "$repo")"
  if [ -n "${n_prs:-}" ] && [ "$n_prs" -ge "$MAX_OPEN_PRS" ]; then
    skipped+="${repo}(${n_prs}prs) "
    continue
  fi
  picked="$repo"
  break
done
printf '%s\n' "$i" >"$CURSOR"

if [ -z "$picked" ]; then
  printf '[%s] nothing started; skipped: %s\n' "$stamp" "$skipped" >>"$LOG"
  notify ":no_entry: jules-rotate started nothing (${stamp})
every repo is busy or over the open-PR limit of ${MAX_OPEN_PRS}:
  ${skipped}"
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
