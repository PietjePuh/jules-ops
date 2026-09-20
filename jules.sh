#!/usr/bin/env bash
# Thin wrapper over the Jules REST API (v1alpha). Reads JULES_API_KEY from the
# environment and never prints it. Intended to be invoked through nova's
# secret_run so the key is injected per call from a 1Password op:// reference.
#
#   jules.sh sources
#   jules.sh ls [pageSize]
#   jules.sh get <sessionId>
#   jules.sh activities <sessionId> [sinceRFC3339]
#   jules.sh new <owner/repo> <prompt> [--branch B] [--title T] [--auto-pr] [--plan-approval]
#   jules.sh msg <sessionId> <text>
#   jules.sh approve <sessionId>
#   jules.sh rm <sessionId>
set -euo pipefail

BASE="https://jules.googleapis.com/v1alpha"
DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JULES_KEY_REF="${JULES_KEY_REF:-op://Agentforce/Jules api/password}"
if [ -z "${JULES_API_KEY:-}" ]; then
  command -v op >/dev/null || { echo "jules: no JULES_API_KEY in env and no op CLI to resolve ${JULES_KEY_REF}" >&2; exit 2; }
  JULES_API_KEY="$(op read "$JULES_KEY_REF")" || { echo "jules: could not resolve ${JULES_KEY_REF}" >&2; exit 2; }
fi
command -v jq >/dev/null || { echo "jules: jq is required" >&2; exit 2; }

# api <METHOD> <path> [json-body]
api() {
  local method="$1" path="$2" body="${3:-}" code tmp out
  tmp="$(mktemp)"
  if [ -n "$body" ]; then
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "x-goog-api-key: ${JULES_API_KEY}" \
      -H 'Content-Type: application/json' \
      -d "$body" "${BASE}${path}")"
  else
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X "$method" \
      -H "x-goog-api-key: ${JULES_API_KEY}" "${BASE}${path}")"
  fi
  out="$(cat "$tmp")"
  rm -f "$tmp"
  case "$code" in
    2*) printf '%s' "${out:-{\}}" ;;
    *)  printf 'jules: %s %s -> HTTP %s\n%s\n' "$method" "$path" "$code" "$out" >&2; return 1 ;;
  esac
}

# resolve_source <owner/repo> -> source resource name, fails if not connected
resolve_source() {
  local want="$1" name
  name="$(api GET "/sources?pageSize=100" \
    | jq -r --arg w "$want" \
      '.sources[]? | select((.githubRepo.owner + "/" + .githubRepo.repo) == $w) | .name' \
    | head -1)"
  if [ -z "$name" ]; then
    echo "jules: '$want' is not a connected Jules source — run 'jules.sh sources'" >&2
    return 1
  fi
  printf '%s' "$name"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  sources)
    api GET "/sources?pageSize=100" | jq -r \
      '.sources[]? | [(.githubRepo.owner + "/" + .githubRepo.repo),
                      (if .githubRepo.isPrivate then "private" else "public" end),
                      .githubRepo.defaultBranch.displayName,
                      .name] | @tsv'
    ;;
  ls)
    api GET "/sessions?pageSize=${1:-20}" | jq -r \
      '.sessions[]? | [.id, .state, .updateTime,
                        ((.title // "-") | gsub("\\s+"; " ") | .[0:64])] | @tsv'
    ;;
  get)
    [ $# -ge 1 ] || { echo "jules: get <sessionId>" >&2; exit 2; }
    api GET "/sessions/$1" | jq .
    ;;
  activities)
    [ $# -ge 1 ] || { echo "jules: activities <sessionId> [sinceRFC3339]" >&2; exit 2; }
    if [ $# -ge 2 ]; then
      api GET "/sessions/$1/activities?createTime=$2" | jq .
    else
      api GET "/sessions/$1/activities" | jq .
    fi
    ;;
  new)
    [ $# -ge 2 ] || { echo "jules: new <owner/repo> <prompt> [--branch B] [--title T] [--auto-pr] [--plan-approval]" >&2; exit 2; }
    repo="$1"; prompt="$2"; shift 2
    branch=""; title=""; auto_pr=false; plan_approval=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --branch)         branch="${2:?--branch needs a value}"; shift 2 ;;
        --title)          title="${2:?--title needs a value}"; shift 2 ;;
        --auto-pr)        auto_pr=true; shift ;;
        --plan-approval)  plan_approval=true; shift ;;
        *) echo "jules: unknown flag '$1'" >&2; exit 2 ;;
      esac
    done
    allow_file="${JULES_ALLOW_FILE:-${DIR_SELF}/repos.allow}"
    if [ ! -f "$allow_file" ]; then
      echo "jules: allowlist ${allow_file} is missing — refusing to create a session" >&2
      exit 3
    fi
    if ! grep -vE '^[[:space:]]*(#|$)' "$allow_file" \
         | grep -qxF -e "$repo" -e "${repo#*/}"; then
      echo "jules: '${repo}' is not in ${allow_file} — refusing to create a session" >&2
      exit 3
    fi
    source_name="$(resolve_source "$repo")"
    [ -n "$branch" ] || branch="$(api GET "/${source_name}" | jq -r '.githubRepo.defaultBranch.displayName')"
    body="$(jq -nc \
      --arg prompt "$prompt" --arg source "$source_name" --arg branch "$branch" \
      --arg title "$title" --argjson autopr "$auto_pr" --argjson approval "$plan_approval" \
      '{prompt: $prompt,
        sourceContext: {source: $source, githubRepoContext: {startingBranch: $branch}},
        requirePlanApproval: $approval}
       + (if $title == "" then {} else {title: $title} end)
       + (if $autopr then {automationMode: "AUTO_CREATE_PR"} else {} end)')"
    api POST "/sessions" "$body" | jq -r '[.id, (.state // "QUEUED"), .url] | @tsv'
    ;;
  msg)
    [ $# -ge 2 ] || { echo "jules: msg <sessionId> <text>" >&2; exit 2; }
    api POST "/sessions/$1:sendMessage" "$(jq -nc --arg p "$2" '{prompt: $p}')" >/dev/null
    echo "sent"
    ;;
  approve)
    [ $# -ge 1 ] || { echo "jules: approve <sessionId>" >&2; exit 2; }
    api POST "/sessions/$1:approvePlan" '{}' >/dev/null
    echo "approved"
    ;;
  rm)
    [ $# -ge 1 ] || { echo "jules: rm <sessionId>" >&2; exit 2; }
    api DELETE "/sessions/$1" >/dev/null
    echo "deleted $1"
    ;;
  *)
    sed -n '2,13p' "$0" >&2
    exit 2
    ;;
esac
