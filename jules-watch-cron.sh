#!/usr/bin/env bash
# Unattended runner for jules-watch.sh. Resolves its own secrets from 1Password
# via the host service account, so no interactive step is required.
# Posts to Slack only when something changed, and always reports its own failures.
#   env: JULES_NOTIFY_DRYRUN=1   print the payload instead of posting
set -euo pipefail

DIR="/var/lib/nova-mcp/work/jules-ops"
export JULES_WATCH_STATE="${DIR}/state.json"
LOG="${DIR}/jules-watch.log"
# shellcheck source=/dev/null
. "${DIR}/notify.sh"

stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"

if [ "${1:-}" = "test" ]; then
  notify ":white_check_mark: jules-watch notification path OK on nova ($stamp)"
  printf 'test notification sent\n'
  exit 0
fi
err="$(mktemp)"

if out="$("${DIR}/jules-watch.sh" 2>"$err")"; then
  if [ -n "$out" ]; then
    printf '[%s] change\n%s\n' "$stamp" "$out" >>"$LOG"
    notify ":robot_face: $out"
  else
    printf '[%s] no change\n' "$stamp" >>"$LOG"
  fi
else
  msg="$(cat "$err")"
  printf '[%s] FAILED\n%s\n' "$stamp" "$msg" >>"$LOG"
  notify ":rotating_light: jules-watch failed on nova ($stamp)
$msg"
  rm -f "$err"
  exit 1
fi
rm -f "$err"
