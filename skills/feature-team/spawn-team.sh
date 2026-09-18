#!/usr/bin/env bash
# Spawn the feature-team starter agents (pm, sa, dev, tester) in a fresh Herdr workspace.
# Usage: spawn-team.sh <slug>
# Models default to opus/opus/sonnet/sonnet; override via PM_MODEL/SA_MODEL/DEV_MODEL/TESTER_MODEL.
set -euo pipefail

command -v jq >/dev/null || { echo "jq required"; exit 1; }
test "${HERDR_ENV:-}" = 1 || { echo "not inside Herdr (HERDR_ENV!=1)"; exit 1; }
slug="${1:?usage: spawn-team.sh <slug>}"

PM_MODEL="${PM_MODEL:-opus}"; SA_MODEL="${SA_MODEL:-opus}"
DEV_MODEL="${DEV_MODEL:-sonnet}"; TESTER_MODEL="${TESTER_MODEL:-sonnet}"

# PM and workers drive agents through the herdr skill — make sure it exists
# where spawned agents load skills (project .claude/skills or $CLAUDE_CONFIG_DIR/skills)
if [ ! -e .claude/skills/herdr ] && [ ! -e "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/herdr" ]; then
  echo "herdr skill not found — installing via skills CLI…"
  if command -v bunx >/dev/null; then
    bunx skills add herdrdev/herdr --skill herdr -y
  else
    npx -y skills add herdrdev/herdr --skill herdr -y
  fi
  [ -e .claude/skills/herdr ] || [ -e "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/herdr" ] \
    || { echo "install ran but herdr skill still missing — install manually: npx skills add herdrdev/herdr --skill herdr"; exit 1; }
fi

# Forward this session's Claude settings (config dir e.g. ~/.claudez, provider, model mappings).
# Never forward CLAUDE_CODE_* — those point at the orchestrating session.
TEAM_ENV=()
for k in CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
         ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
         ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL; do
  if v=$(printenv "$k") && [ -n "$v" ]; then TEAM_ENV+=(--env "$k=$v"); fi
done

# ponytail: sequential herdr calls, no retries — herdr errors bubble up as-is
create=$(herdr workspace create --label "feature: $slug" --focus "${TEAM_ENV[@]}")
ws=$(jq -r '.result.workspace.workspace_id' <<<"$create")
p1=$(jq -r '.result.root_pane.pane_id' <<<"$create")
p2=$(herdr pane split "$p1" --direction right "${TEAM_ENV[@]}" | jq -r '.result.pane.pane_id')
p3=$(herdr pane split "$p1" --direction down "${TEAM_ENV[@]}" | jq -r '.result.pane.pane_id')
p4=$(herdr pane split "$p2" --direction down "${TEAM_ENV[@]}" | jq -r '.result.pane.pane_id')

spawn() { herdr agent start "$1" --kind claude --pane "$2" -- --model "$3" --permission-mode auto; }
spawn pm     "$p1" "$PM_MODEL"
spawn sa     "$p2" "$SA_MODEL"
spawn dev    "$p3" "$DEV_MODEL"
spawn tester "$p4" "$TESTER_MODEL"

for a in pm sa dev tester; do
  herdr agent wait "$a" --until idle --timeout 120000 >/dev/null \
    || echo "warn: $a not idle after 120s (check: herdr agent list)"
done

jq -n --arg ws "$ws" --arg p1 "$p1" --arg p2 "$p2" --arg p3 "$p3" --arg p4 "$p4" \
  '{workspace: $ws, panes: {pm: $p1, sa: $p2, dev: $p3, tester: $p4}, agents: ["pm", "sa", "dev", "tester"]}'
