#!/usr/bin/env bash
# Spawn the feature-team starter agents (pm, sa, dev, tester) in a fresh Herdr workspace.
# Usage: spawn-team.sh <slug>
#
# Agent kind (any kind herdr supports: claude, codex, gemini, cursor, ...):
#   TEAM_KIND            kind for every role                  (default claude)
#   PM_KIND SA_KIND DEV_KIND TESTER_KIND                       (default $TEAM_KIND)
# Agent CLI args, passed verbatim after `--`, whitespace-separated:
#   TEAM_ARGS            args for every role, unless overridden per role
#   PM_ARGS SA_ARGS DEV_ARGS TESTER_ARGS
#   e.g. TEAM_KIND=codex TEAM_ARGS="--model gpt-5-codex --full-auto"
# With no *_ARGS, kind claude defaults to `--model <role model> --permission-mode auto`:
#   PM_MODEL SA_MODEL (default opus), DEV_MODEL TESTER_MODEL (default sonnet)
# Any other kind with no *_ARGS starts bare.
# Env forwarding to the team's panes: see TEAM_ENV_* in agent-env.sh.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

require_deps
slug="${1:?usage: spawn-team.sh <slug>}"

TEAM_KIND="${TEAM_KIND:-claude}"
PM_KIND="${PM_KIND:-$TEAM_KIND}"; SA_KIND="${SA_KIND:-$TEAM_KIND}"
DEV_KIND="${DEV_KIND:-$TEAM_KIND}"; TESTER_KIND="${TESTER_KIND:-$TEAM_KIND}"
PM_ARGS="${PM_ARGS:-${TEAM_ARGS:-}}"; SA_ARGS="${SA_ARGS:-${TEAM_ARGS:-}}"
DEV_ARGS="${DEV_ARGS:-${TEAM_ARGS:-}}"; TESTER_ARGS="${TESTER_ARGS:-${TEAM_ARGS:-}}"
PM_MODEL="${PM_MODEL:-opus}"; SA_MODEL="${SA_MODEL:-opus}"
DEV_MODEL="${DEV_MODEL:-sonnet}"; TESTER_MODEL="${TESTER_MODEL:-sonnet}"

for k in "$PM_KIND" "$SA_KIND" "$DEV_KIND" "$TESTER_KIND"; do validate_kind "$k"; done

# Agents of kind claude drive their teammates through the herdr skill — make
# sure it exists where they load skills (project .claude/skills or
# $CLAUDE_CONFIG_DIR/skills). Other kinds get the herdr commands inline in
# their briefing instead, so skip the install when no role is claude.
case " $PM_KIND $SA_KIND $DEV_KIND $TESTER_KIND " in
  *" claude "*)
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
    ;;
esac

build_team_env

# ponytail: sequential herdr calls, no retries — herdr errors bubble up as-is
create=$(herdr workspace create --label "feature: $slug" --focus "${TEAM_ENV[@]}")
ws=$(jq -r '.result.workspace.workspace_id' <<<"$create")
p1=$(jq -r '.result.root_pane.pane_id' <<<"$create")
p2=$(herdr pane split "$p1" --direction right "${TEAM_ENV[@]}" | jq -r '.result.pane.pane_id')
p3=$(herdr pane split "$p1" --direction down "${TEAM_ENV[@]}" | jq -r '.result.pane.pane_id')
p4=$(herdr pane split "$p2" --direction down "${TEAM_ENV[@]}" | jq -r '.result.pane.pane_id')

spawn() {   # <name> <pane> <kind> <args-var-name> <model>
  resolve_agent_args "${4%_ARGS}" "$3" "${!4:-}" "$5"
  start_agent "$1" "$2" "$3" "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}"
}
spawn pm     "$p1" "$PM_KIND"     PM_ARGS     "$PM_MODEL"
spawn sa     "$p2" "$SA_KIND"     SA_ARGS     "$SA_MODEL"
spawn dev    "$p3" "$DEV_KIND"    DEV_ARGS    "$DEV_MODEL"
spawn tester "$p4" "$TESTER_KIND" TESTER_ARGS "$TESTER_MODEL"

for a in pm sa dev tester; do
  herdr agent wait "$a" --until idle --timeout 120000 >/dev/null \
    || echo "warn: $a not idle after 120s (check: herdr agent list)"
done

jq -n --arg ws "$ws" --arg dir "$here" \
  --arg p1 "$p1" --arg p2 "$p2" --arg p3 "$p3" --arg p4 "$p4" \
  --arg k1 "$PM_KIND" --arg k2 "$SA_KIND" --arg k3 "$DEV_KIND" --arg k4 "$TESTER_KIND" \
  '{workspace: $ws, skill_dir: $dir,
    panes: {pm: $p1, sa: $p2, dev: $p3, tester: $p4},
    kinds: {pm: $k1, sa: $k2, dev: $k3, tester: $k4},
    agents: ["pm", "sa", "dev", "tester"]}'
