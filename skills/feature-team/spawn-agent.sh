#!/usr/bin/env bash
# Spawn one worker agent in a new pane split off a parent pane.
# Usage: spawn-agent.sh <name> <parent-pane-id> [model]
# Env (config dir, provider, model mappings) is forwarded from the caller's
# own environment; the agent runs `claude --permission-mode auto`.
set -euo pipefail

command -v jq >/dev/null || { echo "jq required"; exit 1; }
test "${HERDR_ENV:-}" = 1 || { echo "not inside Herdr (HERDR_ENV!=1)"; exit 1; }
name="${1:?usage: spawn-agent.sh <name> <parent-pane-id> [model]}"
parent="${2:?usage: spawn-agent.sh <name> <parent-pane-id> [model]}"
model="${3:-sonnet}"
[[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "bad name: must match [a-z][a-z0-9_-]{0,31}"; exit 1; }

TEAM_ENV=()
for k in CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
         ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
         ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL; do
  if v=$(printenv "$k") && [ -n "$v" ]; then TEAM_ENV+=(--env "$k=$v"); fi
done

# ponytail: never forward CLAUDE_CODE_* — those point at the orchestrating session

pane=$(herdr pane split "$parent" --direction down "${TEAM_ENV[@]}" | jq -r '.result.pane.pane_id')
herdr agent start "$name" --kind claude --pane "$pane" -- --model "$model" --permission-mode auto >/dev/null
herdr agent wait "$name" --until idle --timeout 120000 >/dev/null \
  || echo "warn: $name not idle after 120s (check: herdr agent list)"

jq -n --arg name "$name" --arg pane "$pane" --arg model "$model" \
  '{name: $name, pane: $pane, model: $model}'
