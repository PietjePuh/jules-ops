#!/usr/bin/env bash
# Weekly proof of life. Silence from the other jobs should mean "nothing
# happened", not "the scheduler died"; this is what tells the two apart.
set -euo pipefail
DIR="/var/lib/nova-mcp/work/jules-ops"
# shellcheck source=/dev/null
. "${DIR}/notify.sh"

stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"
sessions="$("${DIR}/jules.sh" ls 500)"
states="$(cut -f2 <<<"$sessions" | sort | uniq -c | sort -rn | awk '{printf "  %s %s\n", $1, $2}')"
cursor="$(cat "${DIR}/rotate-cursor" 2>/dev/null || echo 0)"
last_rotate="$(tail -1 "${DIR}/jules-rotate.log" 2>/dev/null || echo 'no rotation yet')"

notify ":heartbeat: jules-ops alive (${stamp})
sessions by state:
${states}
rotation cursor: ${cursor}
last rotation: ${last_rotate}"
