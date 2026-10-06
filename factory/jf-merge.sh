#!/bin/sh
# jules-factory: merge -- lands green non-draft factory PRs so the
# live-session budget keeps flowing overnight (repo auto-merge is disabled
# fleet-wide, and harvest deliberately never merges).
#
# Scope guard: ONLY PRs titled "[jules #N]". Merge only when non-draft and
# mergeStateStatus=CLEAN. Control-surface PRs (repos.allow, repos.priority,
# prompts/, .github/workflows/) are NEVER merged here -- policy PRs always
# need Tim's click. Squash + delete branch, same as the manual flow.
# Run every 15m, --no-agent. Silent when nothing to do.
set -eu
. /opt/data/scripts/jules-factory/jf-lib.sh
export PATH=/opt/data/.local/bin:$PATH

GUARD_RE='^(repos\.allow|repos\.priority|prompts/|\.github/workflows/)'

python3 -c "
import json
last = {}
for line in open('$JF_LEDGER'):
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except: continue
    last[(d['repo'], d['issue'])] = d['action']
for (repo, issue), act in last.items():
    if act in ('dispatched', 'readied', 'retried'):
        print(f'{repo}\t{issue}')
" > "$JF_DIR/.merge_cands.$$"

n_merged=0
while IFS="$(printf '\t')" read -r repo issue; do
  [ -z "$repo" ] && continue

  pr=$(gh pr list --repo "$OWNER/$repo" --search "in:title [jules #$issue]" --state open \
       --json number,isDraft,mergeStateStatus \
       --jq '.[0] | select(.isDraft==false and .mergeStateStatus=="CLEAN") | .number' 2>/dev/null || echo "")
  [ -z "$pr" ] && continue

  if gh pr diff "$pr" --repo "$OWNER/$repo" --name-only 2>/dev/null | grep -Eq "$GUARD_RE"; then
    jf_log "merge: SKIP repo=$repo issue=$issue pr=$pr (control-surface guard)"
    continue
  fi

  if gh pr merge "$pr" --repo "$OWNER/$repo" --squash --delete-branch >/dev/null 2>&1; then
    jf_log "merge: OK repo=$repo issue=$issue pr=$pr"
    echo "merged: $repo#$pr (issue #$issue)"
    n_merged=$((n_merged + 1))
  else
    jf_log "merge: FAIL repo=$repo issue=$issue pr=$pr"
  fi
done < "$JF_DIR/.merge_cands.$$"

rm -f "$JF_DIR/.merge_cands.$$"
[ "$n_merged" -gt 0 ] && echo "merge: $n_merged pr(s) this run"
exit 0
