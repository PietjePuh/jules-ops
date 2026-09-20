#!/usr/bin/env bash
# Jules opens its pull requests as drafts. A draft runs no checks and cannot be
# merged, so an auto-merge workflow that fires on a successful check run never
# fires at all. This marks Jules PRs ready for review, which is the step that
# lets the rest of the pipeline work.
#
#   jules-prs.sh list [repo ...]              count open Jules PRs
#   jules-prs.sh ready <repo> [--limit N] [--dry-run]
#   jules-prs.sh dupes <repo>                 group open PRs by normalised title
#   jules-prs.sh close <repo> --superseded|--conflicted|--numbers N,N [--confirm]
#
# close is dry-run unless --confirm is passed. It comments the reason on the PR
# before closing, so the decision is auditable and a close is reopenable.
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

# normalise a Jules PR title: drop the persona prefix and emoji, lowercase,
# collapse whitespace. Two PRs with the same normalised title are the same work
# re-done, not two changes that happen to touch one file.
norm_title() {
  sed -E 's/^[^A-Za-z]*//; s/^(Sentinel|Palette|Bolt)[[:space:]]*:?[[:space:]]*//I' \
    | tr '[:upper:]' '[:lower:]' | tr -s ' ' | sed -E 's/^ +| +$//g'
}

close_pr() { # close_pr <repo> <number> <reason>
  api -X POST "https://api.github.com/repos/${OWNER}/$1/issues/$2/comments" \
      -d "$(jq -nc --arg b "Closed by jules-prs.sh: $3" '{body: $b}')" >/dev/null
  api -X PATCH "https://api.github.com/repos/${OWNER}/$1/pulls/$2" \
      -d '{"state":"closed"}' >/dev/null
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
  dupes)
    repo="${1:?usage: jules-prs.sh dupes <repo>}"
    jules_prs "$repo" | while IFS=$'\t' read -r num draft node title; do
      printf '%s\t%s\n' "$(norm_title <<<"$title")" "$num"
    done | sort | awk -F'\t' '
      { key=$1; nums[key]=nums[key] " #" $2; count[key]++ }
      END { for (k in count) printf "%-3s %s\n  %s\n", count[k], k, nums[k] }' | sort -rn
    ;;
  close)
    repo="${1:?usage: jules-prs.sh close <repo> --superseded|--conflicted|--numbers N,N [--confirm]}"; shift
    mode=""; numbers=""; confirm=0; age_days="${JULES_CLOSE_AGE_DAYS:-7}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --superseded) mode=superseded; shift ;;
        --conflicted) mode=conflicted; shift ;;
        --numbers)    mode=numbers; numbers="${2:?--numbers needs a list}"; shift 2 ;;
        --age-days)   age_days="${2:?--age-days needs a number}"; shift 2 ;;
        --confirm)    confirm=1; shift ;;
        *) echo "jules-prs: unknown flag '$1'" >&2; exit 2 ;;
      esac
    done
    [ -n "$mode" ] || { echo "jules-prs: pick --superseded, --conflicted or --numbers" >&2; exit 2; }
    cutoff="$(date -u -d "-${age_days} days" '+%Y-%m-%dT%H:%M:%SZ')"
    closed=0

    if [ "$mode" = numbers ]; then
      for n in ${numbers//,/ }; do
        if [ "$confirm" -eq 1 ]; then
          close_pr "$repo" "$n" "closed on request"; echo "closed ${repo}#${n}"
        else
          echo "would close ${repo}#${n}"
        fi
        closed=$((closed + 1))
      done
      printf '%s pull request(s) %s\n' "$closed" "$([ "$confirm" -eq 1 ] && echo closed || echo 'would be closed')"
      exit 0
    fi

    # Grouping is done in python: the shell pipeline version could not be shown
    # to keep the newest PR per group, and this tool closes things.
    # Emits "<number>\t<title>" for every PR that is NOT the highest-numbered
    # one in its normalised-title group.
    jules_prs "$repo" | python3 -c '
import sys, re, collections
groups = collections.defaultdict(list)
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 4:
        continue
    num, title = int(parts[0]), parts[3]
    key = re.sub(r"^[^A-Za-z]*", "", title)
    key = re.sub(r"^(Sentinel|Palette|Bolt)\s*:?\s*", "", key, flags=re.I)
    key = re.sub(r"\s+", " ", key).strip().lower()
    groups[key].append((num, title))
for key, items in groups.items():
    items.sort(reverse=True)
    for num, title in items[1:]:
        print(f"{num}\t{title}")
' > /tmp/jp.$$

    if [ "$mode" = superseded ]; then
      while IFS=$'\t' read -r n t; do
        [ -n "${n:-}" ] || continue
        if [ "$confirm" -eq 1 ]; then
          close_pr "$repo" "$n" "superseded by a newer pull request with the same title"
          echo "closed ${repo}#${n}  ${t}"
        else
          echo "would close ${repo}#${n}  ${t}"
        fi
      done < /tmp/jp.$$
    else
      jules_prs "$repo" | cut -f1 | while read -r n; do
        d="$(api "https://api.github.com/repos/${OWNER}/${repo}/pulls/${n}")"
        st="$(jq -r '.mergeable_state' <<<"$d")"
        created="$(jq -r '.created_at' <<<"$d")"
        [ "$st" = dirty ] || continue
        [[ "$created" < "$cutoff" ]] || continue
        if [ "$confirm" -eq 1 ]; then
          close_pr "$repo" "$n" "unmergeable conflicts and older than ${age_days} days"
          echo "closed ${repo}#${n}  conflicts, created ${created:0:10}"
        else
          echo "would close ${repo}#${n}  conflicts, created ${created:0:10}"
        fi
      done
    fi
    rm -f /tmp/jp.$$
    ;;
  *)
    sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
