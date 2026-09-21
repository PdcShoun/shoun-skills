#!/usr/bin/env bash
# Spawn the feature-team starter agents (pm, sa, dev, tester) in a fresh Herdr workspace.
# Usage: spawn-team.sh <slug>
#
# Agent kind (any kind herdr supports: pi, claude, codex, gemini, cursor, ...):
#   TEAM_KIND            kind for every role   (default: the CALLING agent's
#                         own kind — see detect_caller_kind in agent-env.sh;
#                         NEVER defaults to claude for a non-claude caller)
#   PM_KIND SA_KIND DEV_KIND TESTER_KIND                       (default $TEAM_KIND)
# If TEAM_KIND is unset AND the caller's kind can't be detected AND a role has
# no explicit *_KIND, this script fails loudly instead of guessing — set
# TEAM_KIND (or FEATURE_TEAM_CALLER_KIND) explicitly. See feature-team/SKILL.md
# § Provider inheritance for the full precedence.
#
# Agent CLI args, passed verbatim after `--`, whitespace-separated:
#   TEAM_ARGS            args for every role, unless overridden per role
#   PM_ARGS SA_ARGS DEV_ARGS TESTER_ARGS
#   e.g. TEAM_KIND=codex TEAM_ARGS="--model gpt-5-codex --full-auto"
# With no *_ARGS, kind claude defaults to `--model <role model> --permission-mode auto`:
#   PM_MODEL SA_MODEL (default opus), DEV_MODEL TESTER_MODEL (default sonnet)
#   — these model defaults apply ONLY to roles resolved to kind claude; a
#   role resolved to any other kind gets no model default (never pass a
#   claude model name to another provider).
# Any other kind with no *_ARGS starts bare.
# Env forwarding to the team's panes: see TEAM_ENV_* in agent-env.sh.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

require_deps
slug="${1:?usage: spawn-team.sh <slug>}"

# Default provider = the caller's own kind, not a hardcoded one. Explicit
# TEAM_KIND (if set) always wins over detection.
CALLER_KIND="$(detect_caller_kind || true)"
TEAM_KIND="${TEAM_KIND:-$CALLER_KIND}"

PM_KIND="${PM_KIND:-$TEAM_KIND}"; SA_KIND="${SA_KIND:-$TEAM_KIND}"
DEV_KIND="${DEV_KIND:-$TEAM_KIND}"; TESTER_KIND="${TESTER_KIND:-$TEAM_KIND}"

for role_kind in "$PM_KIND" "$SA_KIND" "$DEV_KIND" "$TESTER_KIND"; do
  [ -n "$role_kind" ] || fail_no_provider "TEAM_KIND"
done

PM_ARGS="${PM_ARGS:-${TEAM_ARGS:-}}"; SA_ARGS="${SA_ARGS:-${TEAM_ARGS:-}}"
DEV_ARGS="${DEV_ARGS:-${TEAM_ARGS:-}}"; TESTER_ARGS="${TESTER_ARGS:-${TEAM_ARGS:-}}"

# Model hints are a claude-only concept (see resolve_agent_args). Only default
# them for roles that actually resolved to kind claude; leave every other
# role's model unset so no claude model name leaks into another provider.
[ "$PM_KIND" = claude ] && PM_MODEL="${PM_MODEL:-opus}"
[ "$SA_KIND" = claude ] && SA_MODEL="${SA_MODEL:-opus}"
[ "$DEV_KIND" = claude ] && DEV_MODEL="${DEV_MODEL:-sonnet}"
[ "$TESTER_KIND" = claude ] && TESTER_MODEL="${TESTER_MODEL:-sonnet}"
PM_MODEL="${PM_MODEL:-}"; SA_MODEL="${SA_MODEL:-}"; DEV_MODEL="${DEV_MODEL:-}"; TESTER_MODEL="${TESTER_MODEL:-}"

for k in "$PM_KIND" "$SA_KIND" "$DEV_KIND" "$TESTER_KIND"; do validate_kind "$k"; done

# Provider selection is diagnosable, not just correct — log it (no secrets).
echo "[TEAM] caller=${CALLER_KIND:-unknown} pm=$PM_KIND sa=$SA_KIND dev=$DEV_KIND tester=$TESTER_KIND" >&2

# Export the resolved (not just the user-supplied) kinds so build_team_env
# forwards them into every pane below. This matters even when TEAM_KIND was
# never set by the caller — e.g. a caller detected purely via CLAUDECODE or
# $FEATURE_TEAM_CALLER_KIND never exported TEAM_KIND itself, so without this,
# a pane running kind `pi` would have no signal of its own to re-detect "pi"
# from (there's no PI_-specific env marker), and a PM that later calls
# spawn-agent.sh/spawn-workstream.sh for a retry/resume/workstream would hit
# fail_no_provider instead of reusing the team's actual provider.
export TEAM_KIND PM_KIND SA_KIND DEV_KIND TESTER_KIND
[ -n "${CALLER_KIND:-}" ] && export FEATURE_TEAM_CALLER_KIND="$CALLER_KIND"

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

jq -n --arg ws "$ws" --arg dir "$here" --arg default_branch "$(detect_default_branch)" \
  --arg p1 "$p1" --arg p2 "$p2" --arg p3 "$p3" --arg p4 "$p4" \
  --arg caller "${CALLER_KIND:-}" \
  --arg k1 "$PM_KIND" --arg k2 "$SA_KIND" --arg k3 "$DEV_KIND" --arg k4 "$TESTER_KIND" \
  --argjson role_skills "$(role_skills_json)" \
  '{workspace: $ws, skill_dir: $dir, default_branch: $default_branch,
    panes: {pm: $p1, sa: $p2, dev: $p3, tester: $p4},
    caller_kind: (if $caller == "" then null else $caller end),
    kinds: {pm: $k1, sa: $k2, dev: $k3, tester: $k4},
    role_skills: $role_skills,
    agents: ["pm", "sa", "dev", "tester"]}'
