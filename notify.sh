#!/usr/bin/env bash
# Shared Slack notifier for the jules-ops jobs. Source it, do not execute it.
# Resolves the webhook from 1Password at call time via the host service account.
#   env: JULES_NOTIFY_DRYRUN=1   print the payload instead of posting
#        SLACK_REF               override the op:// reference
SLACK_REF="${SLACK_REF:-op://Agentforce/Slack Webhook - Titan/Webhook URL}"

notify() {
  local text="$1" url
  if [ "${JULES_NOTIFY_DRYRUN:-0}" = "1" ]; then
    printf -- '--- dry run, would POST ---\n%s\n' "$(jq -nc --arg t "$text" '{text: $t}')"
    return 0
  fi
  url="$(op read "$SLACK_REF")"
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "$text" '{text: $t}')" "$url" >/dev/null
}
