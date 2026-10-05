#!/usr/bin/env bash
# Answer a waiting Jules session with a REAL answer derived from what the
# agent actually asked. Replaces the old canned "pick the highest-value item
# and ship" template (retired 2026-10-05): that message ignored the question,
# so agents that asked for requirements got told to "pick a candidate" they
# never had, and sessions died anyway.
#
# Decision flow for one session:
#   AWAITING_PLAN_APPROVAL        -> approve the plan (jules.sh approve)
#   AWAITING_USER_FEEDBACK:
#     last agent message asks for requirements/acceptance criteria
#       and the title carries "[jules #N]"                    -> fetch the
#       issue body via gh and send it (the sandbox cannot read GitHub —
#       this is the #1 stall cause on the account)
#     question mentions credentials/secrets/tokens            -> notify the
#       operator (notify.sh) and tell the agent to proceed with a safe
#       local default; NEVER send or hint at secret material
#     anything else                                            -> quote the
#       question back and answer with an autonomy directive
#     no message extractable                                   -> autonomy
#       directive without the quote (last-resort fallback)
#
# Usage: jules-answer.sh <sessionId>
# Exit codes the sweep distinguishes (2026-10-05):
#   0 = an answer was sent or the plan approved (counts as nudged)
#   3 = skipped: session state moved on since the sweep's snapshot — no
#       message sent; NOT a nudge, NOT a failure, next pass re-evaluates
#       from a fresh session list
#   1 = API failure (counts as a failed attempt, escalates after 2)
#   2 = usage error
set -euo pipefail
DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[ $# -eq 1 ] || { echo "usage: jules-answer.sh <sessionId>" >&2; exit 2; }
id="$1"

AUTONOMY='Proceed autonomously: pick the simplest reasonable option consistent with the issue requirements and the repo conventions, note the decision in the PR description, and do not wait for further input.'

sess="$("${DIR}/jules.sh" get "$id")" || exit 1
state="$(jq -r '.state' <<<"$sess")"
title="$(jq -r '.title // ""' <<<"$sess")"
source="$(jq -r '.sourceContext.source // ""' <<<"$sess")"

if [ "$state" = "AWAITING_PLAN_APPROVAL" ]; then
  "${DIR}/jules.sh" approve "$id" >/dev/null
  printf 'approved plan %s\n' "$id"
  exit 0
fi

[ "$state" = AWAITING_USER_FEEDBACK ] || { printf 'skip %s (state %s)\n' "$id" "$state" >&2; exit 3; }

# Last thing the agent SAID — this is the question to answer.
q="$("${DIR}/jules.sh" activities "$id" 2>/dev/null \
  | jq -r '(.activities // .) | map(select(.agentMessaged.agentMessage != null))
           | last | .agentMessaged.agentMessage // empty')"

if [ -n "$q" ] && printf '%s' "$q" | grep -qiE 'credential|secret|token|api[ -]?key|password|1password|op://'; then
  # Never guess about secrets: flag the human, keep the session moving.
  if [ -x "${DIR}/notify.sh" ] || [ -f "${DIR}/notify.sh" ]; then
    ( . "${DIR}/notify.sh"
      notify ":lock: jules-answer: session ${id} (${title}) is asking for credentials/secrets — manual review needed" ) \
      || true
  fi
  "${DIR}/jules.sh" msg "$id" "I cannot provide credentials or secrets. Proceed with a safe local default (environment variable read, mock, or skip the integration) and document the decision in the PR description. Do not block." >/dev/null
  printf 'answered %s (credentials -> escalated + safe default)\n' "$id"
  exit 0
fi

if [ -n "$q" ] && printf '%s' "$q" | grep -qiE 'requirement|acceptance|criteria|issue (body|details|text)|full (requirements|details)|what (should|do you want)|how (should|do you want)'; then
  # Requirements question. If this is a factory-style session the issue
  # number is in the title and the repo in the source path.
  owner_repo=""
  case "$source" in
    sources/github/*/*) owner_repo="${source#sources/github/}" ;;
  esac
  issue=""
  if [[ "$title" =~ \[jules\ \#([0-9]+)\] ]]; then
    issue="${BASH_REMATCH[1]}"
  fi
  if [ -n "$issue" ] && [ -n "$owner_repo" ] && command -v gh >/dev/null 2>&1; then
    if body="$(gh issue view "$issue" --repo "$owner_repo" --json body --jq .body 2>/dev/null \
               | head -c 6000)" && [ -n "$body" ]; then
      msg="Here are the full requirements from ${owner_repo} issue #${issue} — your sandbox cannot read GitHub, so work from this text:

${body}

Proceed now: follow the repo conventions, make reasonable engineering decisions autonomously, and open the pull request titled exactly: ${title}"
      "${DIR}/jules.sh" msg "$id" "$msg" >/dev/null
      printf 'answered %s (requirements -> issue #%s body, %s chars)\n' "$id" "$issue" "${#body}"
      exit 0
    fi
  fi
  # Requirements asked but no issue reference available — say so honestly.
  "${DIR}/jules.sh" msg "$id" "The full issue text is not available to me either. Proceed with your best reading of the task title and the repo conventions, state your assumptions in the PR description, and do not wait for further input." >/dev/null
  printf 'answered %s (requirements -> honest fallback)\n' "$id"
  exit 0
fi

if [ -n "$q" ]; then
  snippet="$(printf '%s' "$q" | head -c 300)"
  "${DIR}/jules.sh" msg "$id" "Regarding your question — \"${snippet}\" — ${AUTONOMY}" >/dev/null
  printf 'answered %s (quoted question -> autonomy)\n' "$id"
  exit 0
fi

"${DIR}/jules.sh" msg "$id" "$AUTONOMY" >/dev/null
printf 'answered %s (no question found -> autonomy)\n' "$id"
