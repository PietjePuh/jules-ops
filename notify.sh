#!/usr/bin/env bash
# Shared Slack notifier for the jules-ops jobs. Source it, do not execute it.
# Resolves the webhook from 1Password at call time via the host service account.
#   env: JULES_NOTIFY_DRYRUN=1   print the payload instead of posting
#        SLACK_REF               override the op:// reference
SLACK_REF="${SLACK_REF:-op://Agentforce/Slack Webhook - Titan/Webhook URL}"

# Strip ASCII control characters from agent-generated text before it leaves the
# host. Session titles and activity messages are written by Jules, not by us.
sanitize() { tr -d '\000-\010\013\014\016-\037\177'; }

notify() {
  local text stamp
  text="$(printf '%s' "$1" | sanitize)"
  stamp="$(date -u '+%d/%m/%Y %H:%M:%S UTC')"

  case "${JULES_NOTIFY:-log}" in
    off) return 0 ;;
    log)
      # The scheduled task is the notification channel; alerts are written where
      # it reads them rather than pushed to Slack.
      printf -- '--- %s ---\n%s\n' "$stamp" "$text" \
        >> "${JULES_NOTIFY_LOG:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notify.log}"
      return 0
      ;;
  esac

  if [ "${JULES_NOTIFY_DRYRUN:-0}" = "1" ]; then
    printf -- '--- dry run, would POST ---\n%s\n' "$(jq -nc --arg t "$text" '{text: $t}')"
    return 0
  fi
  local url
  url="$(op read "$SLACK_REF")"
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "$text" '{text: $t}')" "$url" >/dev/null
}
