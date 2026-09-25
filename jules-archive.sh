#!/usr/bin/env bash
# Archive every Jules session that has reached a terminal state (COMPLETED or
# FAILED) and has not been archived yet. Appends one JSON line per session to
# jules-history.jsonl: prompt, outcome, repo, and the PR it produced (if any
# open/merged/closed PR on that repo has a matching title -- best-effort,
# Jules doesn't return a PR URL on the session object itself).
#
# Idempotent: archived-seen.json tracks which session IDs have already been
# written, keyed by id -> updateTime, so a session isn't re-appended every
# pass, and IS re-appended (once) if it somehow changes after archiving.
#
#   env: JULES_ARCHIVE_SEEN    state file, default ./archived-seen.json
#        JULES_HISTORY_LOG     output file, default ./jules-history.jsonl
#        JULES_SESSIONS_SRC    read the session TSV from this file (testing)
#        JULES_ARCHIVE_DRYRUN=1  print what would be archived, write nothing
set -euo pipefail

DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OWNER="${JULES_OWNER:-PietjePuh}"
SEEN="${JULES_ARCHIVE_SEEN:-${DIR}/archived-seen.json}"
LOG="${JULES_HISTORY_LOG:-${DIR}/jules-history.jsonl}"
RUNLOG="${DIR}/jules-archive.log"

stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"

if [ -n "${JULES_SESSIONS_SRC:-}" ]; then
  sessions="$(cat "${JULES_SESSIONS_SRC}")"
else
  if ! sessions="$("${DIR}/jules.sh" ls 500 2>&1)"; then
    printf '[%s] FAILED to list sessions\n%s\n' "$stamp" "$sessions" >>"$RUNLOG"
    exit 1
  fi
fi

prev_json="$(cat "$SEEN" 2>/dev/null || echo '{}')"
next_json="$prev_json"
n_archived=0

# best-effort: cache repo -> all Jules PRs (number, title, url, headRefName)
declare -A pr_cache

find_pr_url() { # find_pr_url <repo> <session_id> -> url or empty
  # Jules embeds the session id in its branch name: jules-<id>-<hash>. That is
  # an exact, deterministic link — session TITLE and PR title are unrelated
  # (Jules writes its own PR title), so title matching does not work at all.
  local repo="$1" id="$2" cache_key="$repo"
  if [ -z "${pr_cache[$cache_key]+x}" ]; then
    pr_cache[$cache_key]="$(GH_TOKEN="$(op read "${JULES_PR_TOKEN_REF:-op://Agentforce/leiormsiycti6p6mf4xmtyni44/PAT}" 2>/dev/null)" \
      gh pr list --repo "${OWNER}/${repo}" --state all --limit 200 --search "author:app/google-labs-jules" \
      --json number,title,url,headRefName 2>/dev/null || echo '[]')"
  fi
  jq -r --arg id "$id" '.[] | select(.headRefName | startswith("jules-" + $id + "-")) | .url' <<<"${pr_cache[$cache_key]}" | head -1
}

while IFS=$'\t' read -r id state updated title; do
  [ -n "${id:-}" ] || continue
  case "$state" in COMPLETED|FAILED) ;; *) continue ;; esac

  prev_updated="$(jq -r --arg i "$id" '.[$i] // empty' <<<"$prev_json")"
  [ "$prev_updated" != "$updated" ] || continue   # already archived at this updateTime

  full="$("${DIR}/jules.sh" get "$id" 2>/dev/null || echo '{}')"
  repo="$(jq -r '.sourceContext.source // "" | sub(".*/"; "")' <<<"$full")"
  prompt="$(jq -r '.prompt // ""' <<<"$full")"
  url="$(jq -r '.url // ""' <<<"$full")"
  pr_url=""
  [ -z "$repo" ] || pr_url="$(find_pr_url "$repo" "$id" || true)"

  entry="$(jq -nc \
    --arg id "$id" --arg state "$state" --arg repo "$repo" \
    --arg title "$title" --arg updated "$updated" --arg url "$url" \
    --arg pr_url "$pr_url" --arg prompt "$prompt" --arg archived_at "$stamp" \
    '{id:$id, state:$state, repo:$repo, title:$title, updated:$updated,
      session_url:$url, pr_url:$pr_url, prompt:$prompt, archived_at:$archived_at}')"

  if [ "${JULES_ARCHIVE_DRYRUN:-0}" = "1" ]; then
    printf 'would archive %s (%s) repo=%s pr=%s\n' "$id" "$state" "$repo" "${pr_url:-none}"
  else
    printf '%s\n' "$entry" >>"$LOG"
    # Write the seen-state incrementally, right after each entry lands, not
    # once at the end. A 500-session sweep can run long enough to hit the
    # cron/timeout wall (jules.sh get is one API call per session) --
    # end-of-loop-only writes lost all tracking on the first real run here,
    # which would have re-appended every entry already written as a
    # duplicate on the next pass. jq -c '.[$i] = $u' on the on-disk file
    # keeps this cheap (small JSON object, not the whole session list).
    jq -c --arg i "$id" --arg u "$updated" '.[$i] = $u' "$SEEN" > "${SEEN}.tmp" 2>/dev/null \
      || echo '{}' | jq -c --arg i "$id" --arg u "$updated" '.[$i] = $u' > "${SEEN}.tmp"
    mv "${SEEN}.tmp" "$SEEN"
  fi
  n_archived=$((n_archived + 1))
done <<<"$sessions"

if [ "$n_archived" -gt 0 ]; then
  printf '[%s] archived %s session(s)\n' "$stamp" "$n_archived" >>"$RUNLOG"
else
  printf '[%s] nothing new to archive\n' "$stamp" >>"$RUNLOG"
fi
