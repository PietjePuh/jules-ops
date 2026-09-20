#!/usr/bin/env bash
# Jules opens its pull requests as drafts. A draft runs no checks and cannot be
# merged, so an auto-merge workflow that fires on a successful check run never
# fires at all. This marks Jules PRs ready for review, which is the step that
# lets the rest of the pipeline work.
#
#   jules-prs.sh list [repo ...]              count open Jules PRs
#   jules-prs.sh ready <repo> [--limit N] [--dry-run]
#
#   env: JULES_PR_TOKEN_REF   op:// reference for a GitHub PAT
#        JULES_OWNER          default PietjePuh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNER="${JULES_OWNER:-PietjePuh}"
TOKEN_REF="${JULES_PR_TOKEN_REF:-op://Agentforce/leiormsiycti6p6mf4xmtyni44/PAT}"
: "${GH_PAT:=$(op read "$TOKEN_REF")}"

api() { curl -sS -H "Authorization: Bearer ${GH_PAT}" -H 'Accept: application/vnd.github+json' "$@"; }

# jules_prs <repo> -> number, draft, node_id, mergeable_state, title
jules_prs() {
  api "https://api.github.com/repos/${OWNER}/$1/pulls?state=open&per_page=100" \
    | jq -r '.[] | select(.user.login | test("jules";"i"))
             | [.number, (.draft|tostring), .node_id, (.title[0:60])] | @tsv'
}

cmd="${1:-list}"; shift || true

case "$cmd" in
  list)
    repos=("$@")
    [ ${#repos[@]} -gt 0 ] || mapfile -t repos < <(grep -vE '^[[:space:]]*(#|$)' "${DIR}/repos.allow")
    for r in "${repos[@]}"; do
      out="$(jules_prs "$r")"
      total="$(grep -c . <<<"$out" || true)"
      drafts="$(awk -F'\t' '$2=="true"' <<<"$out" | grep -c . || true)"
      printf '%-22s open=%-4s draft=%s\n' "$r" "$total" "$drafts"
    done
    ;;
  ready)
    repo="${1:?usage: jules-prs.sh ready <repo> [--limit N] [--dry-run]}"; shift
    limit=0; dry=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --limit) limit="${2:?--limit needs a number}"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) echo "jules-prs: unknown flag '$1'" >&2; exit 2 ;;
      esac
    done
    n=0
    while IFS=$'\t' read -r num draft node title; do
      [ -n "${num:-}" ] || continue
      [ "$draft" = true ] || continue
      [ "$limit" -eq 0 ] || [ "$n" -lt "$limit" ] || break
      n=$((n + 1))
      if [ "$dry" -eq 1 ]; then
        printf 'would ready %s#%s  %s\n' "$repo" "$num" "$title"
        continue
      fi
      resp="$(api -X POST https://api.github.com/graphql \
        -d "$(jq -nc --arg id "$node" \
          '{query: "mutation($id:ID!){markPullRequestReadyForReview(input:{pullRequestId:$id}){pullRequest{number isDraft}}}",
            variables: {id: $id}}')")"
      if jq -e '.errors' >/dev/null 2>&1 <<<"$resp"; then
        printf 'FAILED %s#%s: %s\n' "$repo" "$num" "$(jq -c '.errors' <<<"$resp")" >&2
      else
        printf 'ready %s#%s  isDraft=%s  %s\n' "$repo" "$num" \
          "$(jq -r '.data.markPullRequestReadyForReview.pullRequest.isDraft' <<<"$resp")" "$title"
      fi
    done < <(jules_prs "$repo")
    printf '%s draft PR(s) processed\n' "$n"
    ;;
  *)
    sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
