#!/usr/bin/env bash
# jules-autopilot — one unattended management pass, safe to run from boot or a
# timer on ANY fleet host:
#
#   1. sweep: approve pending plans, nudge waiting sessions, escalate stuck ones
#      (delegates to jules-stalled.sh, which owns the attempt/escalation state)
#   2. rotate: start Jules sessions on every eligible repo this pass, up to the
#      account's 100 sessions/day quota (jules-rotate.sh reads the live count
#      from the API and self-limits — no more local "once per day" gate here).
#      Safe to call from multiple hosts concurrently: the quota check is
#      API-truth, not a local file, so fastbelt and nova never double-spend it.
#   3. archive: append every newly-COMPLETED/FAILED session's prompt + outcome
#      + linked PR to jules-history.jsonl (jules-archive.sh owns its own
#      archived-seen.json dedup state, cheap after the first run — it only
#      does real work for sessions that are new since the last pass).
#
#   env: JULES_NOTIFY=off               default: alerts go to notify.log
#        JULES_OPS_DIR                  override the checkout dir
set -uo pipefail

DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LOG="${DIR}/jules-autopilot.log"
STAMP="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"

log() { printf '[%s] %s\n' "$(date -u '+%d/%m/%Y %H:%M:%S UTC')" "$1" >>"$LOG"; }

# 1Password reachability. Preferred: the fleet service account
# (/etc/fleet/op-sa.env, same as nova's cron jobs) — works headless at boot.
# Fallback: the desktop CLI integration. `op whoami` needs a full account
# sign-in and fails even when vault reads work, so probe an actual read.
KEY_REF="${JULES_KEY_REF:-op://Agentforce/fastbelt-env/GLM_API_KEY}"
if [ -r /etc/fleet/op-sa.env ]; then
  set -a; . /etc/fleet/op-sa.env; set +a
fi
if ! op read "$KEY_REF" >/dev/null 2>&1; then
  log "1Password unreachable (no SA file / SA down / desktop locked) — skipping this pass"
  exit 0
fi

log "=== autopilot pass start ==="

# --- 1. sweep ---
if out="$("${DIR}/jules-stalled.sh" 2>&1)"; then
  log "sweep ok: $(head -c 200 <<<"$out" | tr '\n' ' ')"
else
  log "sweep FAILED: $(head -c 300 <<<"$out" | tr '\n' ' ')"
fi

# --- 2. rotate (self-limits to the daily quota via live API count) ---
if out="$("${DIR}/jules-rotate.sh" 2>&1)"; then
  log "rotate ok: $(head -c 300 <<<"$out" | tr '\n' ' ')"
else
  log "rotate FAILED: $(head -c 300 <<<"$out" | tr '\n' ' ')"
fi

# --- 3. archive (bounded cost: only new terminal-state sessions do real work) ---
if out="$("${DIR}/jules-archive.sh" 2>&1)"; then
  log "archive ok: $(head -c 200 <<<"$out" | tr '\n' ' ')"
else
  log "archive FAILED: $(head -c 300 <<<"$out" | tr '\n' ' ')"
fi

log "=== autopilot pass end ==="
