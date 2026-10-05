#!/usr/bin/env bash
# Push stalled sessions past their question by ANSWERING what they actually
# asked (requirements -> issue body, credentials -> escalate, else autonomy).
# See jules-answer.sh for the decision flow.
# Usage: jules-unblock.sh <sessionId> [sessionId ...]
set -euo pipefail
DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[ $# -ge 1 ] || { echo "usage: jules-unblock.sh <sessionId> [...]" >&2; exit 2; }

for id in "$@"; do
  if "${DIR}/jules-answer.sh" "$id"; then
    printf 'unblocked %s\n' "$id"
  else
    printf 'FAILED to unblock %s\n' "$id" >&2
  fi
done
