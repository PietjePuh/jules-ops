#!/usr/bin/env bash
# jules-autopilot — one unattended management pass, safe to run from boot or a
# timer on ANY fleet host:
#
#   1. sweep: approve pending plans, nudge waiting sessions, escalate stuck ones
#      (delegates to jules-stalled.sh, which owns the attempt/escalation state)
#   2. rotate: at most ONE new persona session per day fleet-wide. Detected via
#      the Jules API itself — if any Sentinel/Palette/Bolt session started in the
#      last 24h (by nova's nightly job or another host), nothing new is started.
#      This keeps fastbelt and nova from double-seeding the pipeline.
#
#   env: JULES_AUTOPILOT_FORCE_START=1  start even if one ran in the last 24h
#        JULES_NOTIFY=off               default: alerts go to notify.log
#        JULES_OPS_DIR                  override the checkout dir
set -uo pipefail

DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LOG="${DIR}/jules-autopilot.log"
STAMP="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"

log() { printf '[%s] %s\n' "$(date -u '+%d/%m/%Y %H:%M:%S UTC')" "$1" >>"$LOG"; }

# 1Password must be reachable (desktop CLI-integration unlock on fastbelt,
# service account on nova). `op whoami` needs a full account sign-in and fails
# even when vault reads work, so probe the actual key reference instead.
# If unreachable, skip silently — the next timer pass retries.
KEY_REF="${JULES_KEY_REF:-op://Agentforce/Jules api/password}"
if ! op read "$KEY_REF" >/dev/null 2>&1; then
  log "1Password locked or unreachable (${KEY_REF}) — skipping this pass"
  exit 0
fi

log "=== autopilot pass start ==="

# --- 1. sweep ---
if out="$("${DIR}/jules-stalled.sh" 2>&1)"; then
  log "sweep ok: $(head -c 200 <<<"$out" | tr '\n' ' ')"
else
  log "sweep FAILED: $(head -c 300 <<<"$out" | tr '\n' ' ')"
fi

# --- 2. rotate (once per day, fleet-wide via API state) ---
already=0
if [ "${JULES_AUTOPILOT_FORCE_START:-0}" != "1" ]; then
  cutoff="$(date -u -d '-24 hours' '+%Y-%m-%dT%H:%M:%SZ')"
  # Capture fully, then grep: with pipefail, `grep -q` exiting early SIGPIPEs
  # the upstream jules.sh (still paging) and the pipeline reads as "no match".
  recent="$("${DIR}/jules.sh" ls 500 2>/dev/null | awk -F'\t' -v c="$cutoff" '$3 >= c' || true)"
  if grep -qE '(Sentinel|Palette|Bolt): ' <<<"$recent"; then
    already=1
    log "rotate skipped: a persona session already started in the last 24h"
  fi
fi

if [ "$already" = "0" ]; then
  if out="$("${DIR}/jules-rotate.sh" 2>&1)"; then
    log "rotate ok: $(head -c 200 <<<"$out" | tr '\n' ' ')"
  else
    log "rotate FAILED: $(head -c 300 <<<"$out" | tr '\n' ' ')"
  fi
fi

log "=== autopilot pass end ==="
