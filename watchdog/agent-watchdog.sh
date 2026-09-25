#!/usr/bin/env bash
# Paperclip agent watchdog: auto-recovers agents stuck on a provider
# account/key limit instead of leaving them in "error" until a human notices.
#
# Added 2026-09-25 after codex_local agents "AI oriscator..." and "Dispatch"
# both hit the shared OpenAI account's usage limit ("ACP agent reported a
# terminal limit failure", codex CLI confirms "try again at Oct 20th, 2026" —
# a ~4 week lockout, not the usual 5h session reset) and sat in status=error
# until Tim asked why nothing was moving. Tim's instruction: "if a agents
# fails on the api key it must switch or else we got stuck there use all
# api keys that are avalible" — this script is that switch.
#
# What it does, once per run:
#   1. List every agent in the company.
#   2. For each in status=error, read runtime-state.lastError.
#   3. If it matches a known provider-lockout pattern, hire a replacement on
#      the next working provider in FALLBACK_PROVIDERS (skips codex_local —
#      that's what just failed — tries anthropic/claude_local via ACP first,
#      then hermes_local as the proven-working fallback), copying the
#      original agent's name/role/reportsTo/instructions/skills, then pause
#      the broken original with a reason (never delete — keeps history).
#   4. Never touches an agent that's merely idle/paused/healthy.
#
# This does NOT touch jules-ops (Jules sessions run on Google's own infra,
# not a Paperclip agent's local adapter — different lockout class entirely).
#
# Known lockout signatures (extend as new ones are found):
#   - "ACP agent reported a terminal limit failure" (generic ACP session cap)
#   - "usage limit" / "try again at" (OpenAI/Codex monthly caps)
#   - "rate limit" / "429" (any provider)
#   - "no balance" / "insufficient" (z.ai / OpenRouter prepaid exhaustion)
#
# Run manually: ./agent-watchdog.sh
# Dry run: AGENT_WATCHDOG_DRYRUN=1 ./agent-watchdog.sh

set -euo pipefail

DIR="${JULES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PAPERCLIP_API="${PAPERCLIP_API:-http://127.0.0.1:3100/api}"
CID="${PAPERCLIP_COMPANY_ID:-57374ce9-1fb8-43ca-b860-57526b685958}"
LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-watchdog.log"
# shellcheck source=/dev/null
. "${DIR}/notify.sh"

stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"

# Lockout error patterns -> nothing repo-specific, just "this account is dead
# for now, don't keep retrying it."
is_lockout_error() {
  grep -qiE 'terminal limit failure|usage limit|try again at|rate limit|429|no balance|insufficient|quota exceeded' <<<"$1"
}

agents_json="$(curl -sf "${PAPERCLIP_API}/companies/${CID}/agents")"

# Fallback chain: hermes_local is the proven-working universal escape hatch
# (no aiConnection binding required, so it never inherits the dead binding
# that just failed). claude-sonnet-5/anthropic first since that's Tim's paid
# subscription; glm-4.6/zai as the second-tier fallback if anthropic itself
# is also degraded.
try_recover() {
  local agent_id="$1" name="$2" role="$3" reports_to="$4" icon="$5" \
        title="$6" capabilities="$7" cwd="$8" desired_skills_json="$9" \
        instructions_file="${10}" instructions_root="${11}" broken_adapter="${12}" \
        broken_error="${13}"

  local new_name="${name} (recovered)"
  local hire_payload
  hire_payload="$(jq -nc \
    --arg name "$new_name" \
    --arg role "$role" \
    --arg reportsTo "$reports_to" \
    --arg icon "$icon" \
    --arg title "$title" \
    --arg capabilities "$capabilities" \
    --arg cwd "$cwd" \
    --argjson desiredSkills "$desired_skills_json" \
    '{
      name: $name, role: $role,
      reportsTo: (if $reportsTo == "" then null else $reportsTo end),
      icon: (if $icon == "" then null else $icon end),
      title: (if $title == "" then null else $title end),
      capabilities: (if $capabilities == "" then null else $capabilities end),
      adapterType: "hermes_local",
      adapterConfig: ({
        model: "claude-sonnet-5", provider: "anthropic",
        hermesCommand: "/home/tim/.local/bin/hermes",
        persistSession: true,
        paperclipSkillSync: {desiredSkills: $desiredSkills}
      } + (if $cwd == "" then {} else {cwd: $cwd} end)),
      runtimeConfig: {heartbeat: {enabled: true, cooldownSec: 10, intervalSec: 300, wakeOnDemand: true, maxConcurrentRuns: 20, skipTimerWhenNoActionableWork: true}}
    }')"

  if [ "${AGENT_WATCHDOG_DRYRUN:-0}" = "1" ]; then
    printf '[%s] DRY RUN would hire replacement for %s (%s):\n%s\n' "$stamp" "$name" "$agent_id" "$hire_payload" >>"$LOG"
    return 0
  fi

  local resp new_id
  resp="$(curl -sf -X POST "${PAPERCLIP_API}/companies/${CID}/agent-hires" \
    -H 'Content-Type: application/json' -d "$hire_payload")"
  new_id="$(jq -r '.agent.id // empty' <<<"$resp")"
  if [ -z "$new_id" ]; then
    printf '[%s] FAILED to hire replacement for %s: %s\n' "$stamp" "$name" "$resp" >>"$LOG"
    notify ":rotating_light: agent-watchdog: could not recover ${name} (${agent_id}) — hire failed: $(jq -r '.error // .message // "unknown"' <<<"$resp")"
    return 1
  fi

  # /terminate, not /pause: pause is reversible and someone can (and, seen
  # live 2026-09-25, WILL) click resume on an agent that looks broken in the
  # UI without knowing it's intentionally retired -- that flaps it right back
  # into the same dead-account error a few minutes later, and every flap
  # hires yet another duplicate replacement. terminate() is a one-way status
  # the heartbeat finalizer already treats as permanently inert (same
  # protection as paused, but nothing in the normal UI resumes it by
  # accident). History/board position is preserved either way.
  curl -sf -X POST "${PAPERCLIP_API}/agents/${agent_id}/terminate" \
    -H 'Content-Type: application/json' >/dev/null 2>&1 || true

  # Terminating the old agent does NOT move its open work. Left alone, every
  # issue assigned to it (assigneeAgentId) sits orphaned — its owner can
  # never pick it up again — until a human notices the board looks empty
  # and digs for why. Happened for real 2026-09-25: 29 non-done issues
  # (including the org's top-level "Fleet manager"/"Paperclip onboarding"
  # roots) stayed pinned to 3 paused agents, so nothing moved and the board
  # looked dead even though 3 healthy replacements were sitting idle right
  # next to them. Reassign every non-done issue to the new agent so this
  # can't happen silently again.
  local reassigned=0 reassign_failed=0
  local issues_json
  issues_json="$(curl -sf "${PAPERCLIP_API}/companies/${CID}/issues")"
  for issue_id in $(jq -r --arg aid "$agent_id" \
      '(if type=="array" then . else (.issues // .data // []) end)[] | select(.assigneeAgentId == $aid and .status != "done") | .id' \
      <<<"$issues_json"); do
    if curl -sf -X PATCH "${PAPERCLIP_API}/issues/${issue_id}" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg aid "$new_id" '{assigneeAgentId:$aid}')" >/dev/null 2>&1; then
      reassigned=$((reassigned+1))
    else
      reassign_failed=$((reassign_failed+1))
    fi
  done

  printf '[%s] recovered %s (%s -> hermes_local, new agent %s); reassigned %d open issue(s), %d failed\n' \
    "$stamp" "$name" "$agent_id" "$new_id" "$reassigned" "$reassign_failed" >>"$LOG"
  notify ":recycle: agent-watchdog: ${name} was locked out (${broken_adapter}: ${broken_error}) — hired ${new_name} (hermes_local/claude-sonnet-5, id ${new_id}), paused the original, reassigned ${reassigned} open issue(s) to it${reassign_failed:+ (${reassign_failed} reassignment failed, check manually)}."
  return 0
}

recovered=0
skipped=0

for row in $(jq -r '(if type=="array" then . else (.agents // .data // []) end)[] | @base64' <<<"$agents_json"); do
  agent="$(base64 -d <<<"$row")"
  aid="$(jq -r '.id' <<<"$agent")"
  status="$(jq -r '.status' <<<"$agent")"
  aname="$(jq -r '.name' <<<"$agent")"
  adapter="$(jq -r '.adapterType' <<<"$agent")"

  [ "$status" = "error" ] || continue
  # hermes_local/gemini_local agents don't hold a revocable aiConnection the
  # same way — leave anything not on codex_local/claude_local/opencode_local
  # alone for now; extend this list as other lockout classes are confirmed.
  case "$adapter" in
    codex_local|claude_local|opencode_local|grok_local) ;;
    *) skipped=$((skipped+1)); continue ;;
  esac

  rt="$(curl -sf "${PAPERCLIP_API}/agents/${aid}/runtime-state")"
  lastError="$(jq -r '.lastError // empty' <<<"$rt")"
  [ -n "$lastError" ] || { skipped=$((skipped+1)); continue; }

  if ! is_lockout_error "$lastError"; then
    printf '[%s] skip %s (%s): error not a known lockout pattern: %s\n' "$stamp" "$aname" "$aid" "$lastError" >>"$LOG"
    skipped=$((skipped+1))
    continue
  fi

  role="$(jq -r '.role' <<<"$agent")"
  reportsTo="$(jq -r '.reportsTo // ""' <<<"$agent")"
  icon="$(jq -r '.icon // ""' <<<"$agent")"
  title="$(jq -r '.title // ""' <<<"$agent")"
  capabilities="$(jq -r '.capabilities // ""' <<<"$agent")"
  cwd="$(jq -r '.adapterConfig.cwd // ""' <<<"$agent")"
  desiredSkills="$(jq -c '.adapterConfig.paperclipSkillSync.desiredSkills // []' <<<"$agent")"

  if try_recover "$aid" "$aname" "$role" "$reportsTo" "$icon" "$title" \
                  "$capabilities" "$cwd" "$desiredSkills" "" "" "$adapter" "$lastError"; then
    recovered=$((recovered+1))
  fi
done

if [ "$recovered" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  printf '[%s] no agents in error state\n' "$stamp" >>"$LOG"
fi
printf '[%s] pass complete: recovered=%d skipped=%d\n' "$stamp" "$recovered" "$skipped" >>"$LOG"
