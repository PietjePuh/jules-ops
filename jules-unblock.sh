#!/usr/bin/env bash
# Push stalled sessions past their question: tell the agent to decide and ship.
# Usage: jules-unblock.sh <sessionId> [sessionId ...]
set -euo pipefail
DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[ $# -ge 1 ] || { echo "usage: jules-unblock.sh <sessionId> [...]" >&2; exit 2; }

MSG='Pick the single highest-value item from the candidates you listed and implement it now. Do not ask any further questions and do not present options. Run the repository lint and test commands, then open a pull request. If none of the candidates qualifies, stop without opening a pull request.'

for id in "$@"; do
  if "${DIR}/jules.sh" msg "$id" "$MSG" >/dev/null; then
    printf 'unblocked %s\n' "$id"
  else
    printf 'FAILED to unblock %s\n' "$id" >&2
  fi
done
