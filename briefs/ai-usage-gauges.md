Add a new "AI Usage" section to the Agents tab of the Toolbelt bar plugin
(io.github.pietjepuh.toolbelt), showing per-provider usage/quota gauges for
the AI backends Tim's Paperclip agent fleet uses: Claude, OpenAI Codex, z.ai
(GLM), and OpenRouter.

## Why
Tim runs an autonomous agent fleet on Paperclip across multiple AI providers.
A Claude session-limit lockout recently burned tokens on failed retries for
hours before being noticed, because nothing surfaced the exhausted quota in
the UI. An always-visible per-provider usage gauge in the bar should make an
exhausted quota immediately visible.

## IMPORTANT: build this independently, do not copy or study any specific
## third-party "usage bar" project's source code or structure. Similar tools
## exist in the Omarchy plugin community (waybar/quickshell AI-usage widgets)
## — do not clone, read, or port logic from any of them. Discover the
## necessary facts yourself from first principles / official sources only:
## - Read each CLI's OWN local credential file to understand its format
##   (you have Claude Code and Codex CLI installed locally on this box —
##   inspect ~/.claude/.credentials.json and ~/.codex/auth.json structure
##   yourself, they are plain JSON).
## - Find each provider's OFFICIAL usage/quota API by reading their official
##   API documentation (Anthropic's docs, OpenAI's docs, z.ai/Zhipu docs,
##   OpenRouter's docs) — not by reverse-engineering someone else's client.
## - If no official usage endpoint exists for a provider, it's fine to only
##   show what's derivable from your own request/response logs, or to skip
##   that provider's gauge entirely with a clear comment explaining why.
## This is a hard requirement: any code found to be copied or closely
## paraphrased from a third-party repo will be rejected in review, even with
## attribution. Original work only.

## What to build
1. `bin/ai_usage.py` — new engine module (stdlib only — no new pip deps —
   following the existing pattern of bin/security.py, bin/devices.py: each
   subcommand prints exactly one JSON object). For each provider (Claude,
   Codex, z.ai, OpenRouter):
   - Read the credential/API key from its standard local location (Claude:
     ~/.claude/.credentials.json `claudeAiOauth.accessToken`; Codex:
     ~/.codex/auth.json `tokens.access_token`; z.ai/OpenRouter: environment
     variable or 1Password, following the existing pattern other bin/*.py
     files in this repo use for credential resolution).
   - Call that provider's official usage/rate-limit API (research the exact
     endpoint and response shape yourself from official docs).
   - Return normalized fields: percent used, reset time/countdown, plan/tier
     label if available.
   - Degrade honestly (omit that provider's gauge, no error) when its
     credential is absent or the API call fails — this matches the existing
     "degrades honestly when absent" convention already documented in
     README.md's Requirements section.
2. Extend BarWidget.qml's Agents tab with a new "AI Usage" panel section: one
   compact gauge/bar per available provider (label, %, reset countdown),
   reusing the existing phosphor dark-green design language (see
   manifest.json's description "UI v3 'phosphor'"). Two-clone sync rule:
   edit ONLY this checkout (~/github/omarchy-toolbelt) — do NOT touch the
   separate live plugin clone at
   ~/.config/omarchy/plugins/io.github.pietjepuh.toolbelt.
3. Add a manifest.json schema entry (settings toggle), pattern-matched on the
   existing `showThreat`/`showWeather` entries: `showAiUsage` (boolean,
   default true).
4. Wire bin/toolbelt_agent.py's ACTIONS bridge to expose the new subcommand
   if that pattern applies — check the existing sec.*/dev.* wiring first for
   the convention to follow.
5. Add a test under test/ following whatever test conventions already exist
   in that directory.
6. Update README.md's Architecture section with a one-line description of
   bin/ai_usage.py, matching the style of the existing bin/*.py bullet points.

## Constraints
- Keep the diff reviewable and scoped to usage/quota display only. Don't
  touch OMCP (tsouth89.omcp stays foreign/untouched per existing project
  convention — see repo's CLAUDE.md/AGENTS.md/skill notes if present).
- Never print, log, or persist actual API keys or OAuth tokens anywhere —
  only the derived usage numbers.
- Run qmllint on any .qml file you touch before finishing, and run the
  project's own lint/test commands (see CLAUDE.md/AGENTS.md if present).
- Open ONE pull request titled "AI Usage: per-provider quota gauges in Agents
  tab", describing in the PR body exactly which official API/doc source you
  used per provider. Do not ask questions; make the best judgment call and
  ship it. If a provider truly has no discoverable usage API, say so in the
  PR body and ship the others.
