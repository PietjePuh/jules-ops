#!/usr/bin/env bash
# Scope guard for jules-stalled.sh (TIM-291): is a Jules session's repo in
# scope? Mirrors the rotator's fail-closed reading of repos.allow so the stall
# sweep never nudges, approves, or re-wakes a session on a repo Tim narrowed
# out of Jules' remit (25/09: "keep omarchy-toolbelt and toolbelt and
# airplanesole not te rest and dotfiles"). The sweep acts on candidates from
# the WHOLE account session list; without this guard a live-but-stalled
# session on an out-of-scope repo gets woken by the account's own sweep.
#
#   env: JULES_SCOPE_OFF=1   disable the guard (emergency bypass)
#
# Fail-closed on purpose, twice:
#   1. repos.allow unreadable -> the last-good cache at .scope/repos.allow.
#      last-good; that cache is itself never committed (gitignored).
#   2. BOTH unreadable -> exit 0 with empty output. An empty stdout classifies
#      EVERY candidate out-of-scope: the sweep skips and records it rather
#      than acting on a repo list it cannot verify.
#
# jules.sh matches bare repo names (jules-ops CI asserts no owner prefixes),
# so entries are compared verbatim: no normalization, no case folding.
set -uo pipefail

DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ALLOW="${JULES_ALLOWLIST:-${DIR}/repos.allow}"
CACHE_DIR="${JULES_SCOPE_CACHE_DIR:-${DIR}/.scope}"
CACHE="${CACHE_DIR}/repos.allow.last-good"

if [ "${JULES_SCOPE_OFF:-0}" = "1" ]; then
  printf '%s\n' '*'
  exit 0
fi

read_list() {
  grep -vE '^\s*(#|$)' "$1" 2>/dev/null
}

entries="$(read_list "$ALLOW")"
if [ -n "$entries" ]; then
  mkdir -p "$CACHE_DIR" 2>/dev/null || true
  tmp="$(mktemp "${CACHE_DIR}/.tmp.XXXXXX")" && \
    printf '%s\n' "$entries" >"$tmp" && mv -f "$tmp" "$CACHE"
elif [ -r "$CACHE" ]; then
  # Last-good fallback: the cache is the same allowlist the previous passes
  # enforced with, byte-for-byte, not a broader list.
  entries="$(read_list "$CACHE")"
fi

printf '%s\n' "$entries"
