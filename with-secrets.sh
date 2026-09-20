#!/usr/bin/env bash
# cron starts with an empty environment, so `op` has no service-account token and
# every op:// reference fails. The fleet keeps that token in a root-owned,
# group-readable env file; source it and exec the real job. No secret is stored
# in this repo — only the path to the file the fleet already maintains.
set -euo pipefail
ENV_FILE="${FLEET_OP_ENV:-}"
if [ -z "$ENV_FILE" ]; then
  for c in /etc/nova-mcp/env /etc/fleet/op-sa.env; do
    [ -r "$c" ] || continue
    grep -q '^OP_SERVICE_ACCOUNT_TOKEN=' "$c" || continue
    ENV_FILE="$c"; break
  done
fi
if [ -z "$ENV_FILE" ] || [ ! -r "$ENV_FILE" ]; then
  echo "with-secrets: no readable env file defining OP_SERVICE_ACCOUNT_TOKEN" >&2
  exit 3
fi
# cron.log has no structure of its own: entries from `op` and from curl carry no
# timestamps, so an old failure is indistinguishable from a current one. Stamp
# every invocation, and keep the file from growing without bound.
LOG="${JULES_CRON_LOG:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cron.log}"
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1048576 ]; then
  tail -c 262144 "$LOG" > "${LOG}.trim" && mv "${LOG}.trim" "$LOG"
fi
printf -- '--- %s %s ---\n' "$(date -u '+%d/%m/%Y %H:%M:%S UTC')" "$(basename "${1:-?}")"

set -a; . "$ENV_FILE"; set +a
: "${OP_SERVICE_ACCOUNT_TOKEN:?with-secrets: ${ENV_FILE} did not define OP_SERVICE_ACCOUNT_TOKEN}"
exec "$@"
