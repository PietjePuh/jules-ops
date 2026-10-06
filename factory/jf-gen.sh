#!/bin/sh
# jules-factory: gen -- rebuild tasks.jsonl from GitHub issues labelled
# "jules" across every PietjePuh repo. Idempotent full rebuild; the
# LEDGER (not this file) decides what has already been dispatched.
# Run hourly, --no-agent (pure script, zero LLM tokens).
set -eu
. /opt/data/scripts/jules-factory/jf-lib.sh

TMP="$JF_TASKS.tmp.$$"

gh search issues --owner "$OWNER" --label jules --state open \
  --json repository,number,title,url --limit 500 2>>"$JF_LOG" \
  | python3 -c "
import json, sys
items = json.load(sys.stdin)
for it in items:
    repo = it['repository']['name']
    print(json.dumps({
        'repo': repo,
        'issue': it['number'],
        'title': it['title'],
        'url': it['url'],
    }))
" > "$TMP"

n=$(wc -l < "$TMP" | tr -d ' ')
mv "$TMP" "$JF_TASKS"
jf_log "gen: rebuilt tasks.jsonl, $n open jules-labelled issues found"
echo "gen: $n task(s)"
