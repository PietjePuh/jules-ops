#!/usr/bin/env bash
# Watch public Jules release surfaces (GitHub + npm) and report what changed
# since the last run. Prints nothing when nothing changed, so it is cron-safe.
#
#   env: GITHUB_TOKEN        optional, raises the GitHub rate limit
#        JULES_WATCH_STATE   optional, state file path
set -euo pipefail

STATE="${JULES_WATCH_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/jules-watch/state.json}"
REPOS=(
  google-labs-code/jules-sdk
  google-labs-code/jules-action
  google-labs-code/jules-skills
  google-labs-code/jules-awesome-list
)
PKGS=(@google/jules @google/jules-sdk)

command -v jq >/dev/null || { echo "jules-watch: jq is required" >&2; exit 2; }

gh_auth=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  gh_auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

# gh_get <api-path> -> JSON body on stdout, "null" on 404, hard fail otherwise.
gh_get() {
  local url="https://api.github.com/$1" code tmp body
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${gh_auth[@]}" "$url")"
  body="$(cat "$tmp")"
  rm -f "$tmp"
  case "$code" in
    200) printf '%s' "$body" ;;
    404) printf 'null' ;;
    *)   printf 'jules-watch: GET %s -> HTTP %s\n%s\n' "$url" "$code" "$body" >&2; return 1 ;;
  esac
}

snapshot() {
  local out='{"repos":{},"npm":{}}' slug rel commits pkg meta
  for slug in "${REPOS[@]}"; do
    rel="$(gh_get "repos/${slug}/releases/latest")"
    commits="$(gh_get "repos/${slug}/commits?per_page=1")"
    out="$(jq -c \
      --arg slug "$slug" \
      --argjson rel "$rel" \
      --argjson commits "$commits" \
      '.repos[$slug] = {
         release:     ($rel.tag_name // "none"),
         release_at:  ($rel.published_at // "none"),
         commit:      (($commits[0].sha // "none")[0:12]),
         commit_at:   ($commits[0].commit.committer.date // "none")
       }' <<<"$out")"
  done
  for pkg in "${PKGS[@]}"; do
    meta="$(curl -fsS "https://registry.npmjs.org/${pkg}")"
    out="$(jq -c \
      --arg pkg "$pkg" \
      --argjson meta "$meta" \
      '.npm[$pkg] = {
         version: $meta["dist-tags"].latest,
         at:      $meta.time[$meta["dist-tags"].latest]
       }' <<<"$out")"
  done
  printf '%s' "$out"
}

flatten() { jq -r 'paths(scalars) as $p | "\($p | join(" "))\t\(getpath($p))"'; }

new_json="$(snapshot)"
mkdir -p "$(dirname "$STATE")"

if [ ! -f "$STATE" ]; then
  printf '%s\n' "$new_json" >"$STATE"
  printf 'jules-watch: baseline written to %s (%s tracked values)\n' \
    "$STATE" "$(flatten <<<"$new_json" | wc -l)"
  exit 0
fi

changed="$(comm -13 \
  <(flatten <"$STATE" | sort) \
  <(flatten <<<"$new_json" | sort) || true)"

printf '%s\n' "$new_json" >"$STATE"

[ -n "$changed" ] || exit 0

printf 'Jules release surface changed (%s):\n' "$(date -u '+%d/%m/%Y %H:%M:%S UTC')"
while IFS=$'\t' read -r key value; do
  [ -n "$key" ] || continue
  printf '  %-52s %s\n' "$key" "$value"
done <<<"$changed"
