#!/usr/bin/env bash
# Paperclip board-health watchdog: catches silent CONFIG DRIFT, not provider
# lockouts (that's agent-watchdog.sh's job — different failure class).
#
# Added 2026-10-03 after three drift bugs found by hand in one session:
#   1. "GLM Runner"'s model field was "Glm 5.3 Flash" (wrong case/spacing).
#      hermes does NOT error on an unrecognized model string for the zai
#      provider -- it silently falls back to a generic default
#      (glm-5.3-flash) and answers normally, so the agent LOOKED healthy
#      while quietly running the wrong model. Proven with:
#        hermes -z '...' -m "totally-bogus-model-xyz" --provider zai
#      returning glm-5.3-flash every time, no error, exit 0.
#   2. The Chief/"AI oriscator" agent's adapterConfig had NO model key at
#      all (same silent-fallback exposure, plus it couldn't actually run).
#   3. Two heartbeats + two budget caps got silently reset/dropped at some
#      point between being set and being re-checked.
# And a fourth standing problem: the Paperclip kanban board was found 100%
# "done"/"cancelled" (265/265) with zero backlog for Toolbelt or
# omarchy-toolbelt -- nothing refills it automatically when agents drain it.
#
# This script is config-driven (board-health-config.json): it does NOT
# invent what a model/heartbeat/budget "should" be, it enforces the roster
# recorded there. Update that file, not this script, when the fleet changes.
#
# What it deliberately does NOT do:
#   - Resume a manually-paused agent. Pausing is a cost/business decision;
#     this script notifies but never overrides it.
#   - Touch status=error agents. That's agent-watchdog.sh (provider lockout
#     recovery via hire-a-replacement). Different bug class entirely.
#   - Duplicate a kanban card for a GitHub issue any EXISTING Paperclip
#     issue (done or not) already references -- dedup is a substring check
#     on "<owner>/<repo>#<number>" across every issue's description.
#   - Create cards from open PRs. PR grooming is Relay 2's standing job via
#     its own heartbeat routine; a kanban card per PR would just be noise.
#
# Run manually: ./board-health-watchdog.sh
# Dry run (no writes, only logs what it WOULD do): BOARD_WATCHDOG_DRYRUN=1 ./board-health-watchdog.sh

set -euo pipefail

DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${BOARD_WATCHDOG_CONFIG:-${SELFDIR}/board-health-config.json}"
LOG="${SELFDIR}/board-health-watchdog.log"
# shellcheck source=/dev/null
. "${DIR}/notify.sh"

PAPERCLIP_API="$(jq -r '.paperclip_api' "$CONFIG")"
CID="$(jq -r '.company_id' "$CONFIG")"
DRYRUN="${BOARD_WATCHDOG_DRYRUN:-0}"
stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"

log() { printf '[%s] %s\n' "$stamp" "$1" >>"$LOG"; }

fixed=0
declare -a alerts=()

# NOTE on delimiter: bash's `read` treats IFS as "IFS whitespace splitting"
# (squeezes consecutive delimiters, silently dropping empty fields) whenever
# IFS consists solely of space/tab/newline -- even if you set it to ONE tab
# character on purpose. A record with an empty middle field (e.g. provider:
# "" for gemini_local agents) then silently shifts every later column.
# Proven 2026-10-03: `IFS=$'\t' read -r w x y z <<<$'a\tb\t\td'` yields
# x=b y=d z=(empty) instead of the expected y=(empty) z=d. Fix: join on the
# ASCII unit separator (0x1F), which is NOT whitespace, so empty fields
# survive intact.
US=$'\x1f'

# ---------- Section A: per-agent model / provider / heartbeat / budget enforcement ----------
while IFS="$US" read -r aid aname emodel eprovider ehb ebudget; do
  live="$(curl -sf "${PAPERCLIP_API}/agents/${aid}")" || { log "FETCH FAILED for ${aname} (${aid})"; continue; }
  status="$(jq -r '.status' <<<"$live")"
  lmodel="$(jq -r '.adapterConfig.model // ""' <<<"$live")"
  lprovider="$(jq -r '.adapterConfig.provider // ""' <<<"$live")"
  lhb="$(jq -r '.runtimeConfig.heartbeat.enabled // false' <<<"$live")"
  lbudget="$(jq -r '.budgetMonthlyCents // "null"' <<<"$live")"

  # Model and/or provider drift (covers both the "wrong string" and the
  # "missing entirely" case -- both exposed the silent-fallback bug).
  need_model_fix=0
  [ -n "$emodel" ] && [ "$lmodel" != "$emodel" ] && need_model_fix=1
  [ -n "$eprovider" ] && [ "$lprovider" != "$eprovider" ] && need_model_fix=1

  if [ "$need_model_fix" = "1" ]; then
    log "MODEL/PROVIDER DRIFT ${aname}: model='${lmodel}' provider='${lprovider}' expected model='${emodel}' provider='${eprovider}'"
    if [ "$DRYRUN" != "1" ]; then
      newac="$(jq -c --arg m "$emodel" --arg p "$eprovider" \
        '.adapterConfig + {model: $m} + (if $p == "" then {} else {provider: $p} end)' <<<"$live")"
      curl -sf -X PATCH "${PAPERCLIP_API}/agents/${aid}" -H 'Content-Type: application/json' \
        -d "$(jq -nc --argjson ac "$newac" '{adapterConfig: $ac}')" >/dev/null
      fixed=$((fixed+1))
    fi
    alerts+=("model-drift: ${aname} was '${lmodel}'/'${lprovider}', reset to '${emodel}'/'${eprovider}'")
  fi

  # Heartbeat drift: only force ON for roster entries marked heartbeat:true,
  # and only while the agent isn't paused (pause makes the flag moot and we
  # never want to fight a deliberate pause).
  if [ "$ehb" = "true" ] && [ "$status" != "paused" ] && [ "$lhb" != "true" ]; then
    log "HEARTBEAT DRIFT ${aname}: disabled, expected enabled"
    if [ "$DRYRUN" != "1" ]; then
      curl -sf -X PATCH "${PAPERCLIP_API}/agents/${aid}" -H 'Content-Type: application/json' \
        -d '{"runtimeConfig":{"heartbeat":{"enabled":true,"intervalSec":300,"cooldownSec":10,"wakeOnDemand":true,"maxConcurrentRuns":1,"skipTimerWhenNoActionableWork":true}}}' >/dev/null
      fixed=$((fixed+1))
    fi
    alerts+=("heartbeat-drift: ${aname} re-enabled")
  fi

  # Budget cap drift (re-applies if dropped back to null/unlimited).
  if [ "$ebudget" != "null" ] && [ "$lbudget" != "$ebudget" ]; then
    log "BUDGET DRIFT ${aname}: ${lbudget} != expected ${ebudget}"
    if [ "$DRYRUN" != "1" ]; then
      curl -sf -X PATCH "${PAPERCLIP_API}/agents/${aid}/budgets" -H 'Content-Type: application/json' \
        -d "$(jq -nc --argjson b "$ebudget" '{budgetMonthlyCents: $b}')" >/dev/null
      fixed=$((fixed+1))
    fi
    alerts+=("budget-drift: ${aname} reset to \$$((ebudget / 100))/mo cap")
  fi

  # Manual pause on a should-be-active roster member: surface it, never
  # auto-resume -- resuming is a cost decision only Tim makes.
  if [ "$ehb" = "true" ] && [ "$status" = "paused" ]; then
    preason="$(jq -r '.pauseReason // ""' <<<"$live")"
    if [ "$preason" = "manual" ]; then
      alerts+=("needs-human: ${aname} is manually paused -- resume it yourself if intended")
    fi
  fi
done < <(jq -r --arg us "$US" \
  '.agents[] | [.id, .name, .model, (.provider // ""), (.heartbeat|tostring), (.budget_cents|tostring)] | join($us)' \
  "$CONFIG")

# ---------- Section B: kanban board refill ----------
min_active=$(jq -r '.min_active_cards_per_repo' "$CONFIG")
all_issues_json="$(curl -sf "${PAPERCLIP_API}/companies/${CID}/issues")"
mapfile -t pool_ids < <(jq -r '.refill_assignee_pool[]' "$CONFIG")
pool_i=0
next_assignee() { local a="${pool_ids[$((pool_i % ${#pool_ids[@]}))]}"; pool_i=$((pool_i+1)); printf '%s' "$a"; }

while IFS= read -r repo; do
  short="${repo#*/}"
  active_count=$(jq --arg s "$short" \
    '[.[] | select(((.title // "") | contains($s)) and (.status != "done") and (.status != "cancelled"))] | length' \
    <<<"$all_issues_json")
  log "repo ${repo}: ${active_count} active kanban card(s) (threshold ${min_active})"
  [ "$active_count" -ge "$min_active" ] && continue

  log "BOARD DRAINED for ${repo} -- checking GitHub for open issues to mirror"
  gh_issues="$(gh issue list --repo "$repo" --state open --json number,title,url --limit 50 2>/dev/null || echo '[]')"

  while IFS="$US" read -r num title url; do
    [ -z "$num" ] && continue
    ref="${repo}#${num}"
    exists=$(jq --arg ref "$ref" '[.[] | select((.description // "") | contains($ref))] | length' <<<"$all_issues_json")
    [ "$exists" -gt 0 ] && continue

    card_title="${short}: ${title}"
    card_desc="GitHub issue ${ref}. ${url}"
    assignee="$(next_assignee)"
    log "creating kanban card for ${ref}: ${title}"
    if [ "$DRYRUN" != "1" ]; then
      resp="$(curl -sf -X POST "${PAPERCLIP_API}/companies/${CID}/issues" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg t "$card_title" --arg d "$card_desc" '{title:$t, description:$d, status:"todo"}')")"
      ident="$(jq -r '.identifier' <<<"$resp")"
      curl -sf -X PATCH "${PAPERCLIP_API}/issues/${ident}" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg a "$assignee" '{assigneeAgentId:$a}')" >/dev/null
      brief="TASK: ${ref} -- ${title}. Read the full issue body on GitHub (${url}) before starting. Open a PR, link back to ${ref} in the description, and never merge a sensitive-path or security-relevant change without calling out the risk explicitly."
      curl -sf -X POST "${PAPERCLIP_API}/issues/${ident}/comments" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg b "$brief" '{body:$b}')" >/dev/null
      fixed=$((fixed+1))
      alerts+=("board-refill: created ${ident} for ${ref} (assigned)")
    fi
  done < <(jq -r --arg us "$US" '.[] | [.number, .title, .url] | join($us)' <<<"$gh_issues")
done < <(jq -r '.repos[]' "$CONFIG")

# ---------- wrap up ----------
if [ "${#alerts[@]}" -gt 0 ]; then
  summary=""
  for a in "${alerts[@]}"; do summary="${summary}${a}; "; done
  notify ":hammer_and_wrench: board-health-watchdog: ${summary}"
fi
log "pass complete: fixed=${fixed} alerts=${#alerts[@]}"
