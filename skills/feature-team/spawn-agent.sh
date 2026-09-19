#!/usr/bin/env bash
# Spawn one worker agent in a new pane split off a parent pane. The new pane
# SHARES the parent's working tree — safe only for a helper that runs
# sequentially with (or reads without writing alongside) everything else in
# that tree. For a second concurrent code-writing workstream, use
# spawn-workstream.sh instead, which gives the worker its own Git worktree so
# two agents never touch the same working tree at once.
# Usage: spawn-agent.sh <name> <parent-pane-id> [agent-args...]
#
# Extra positional args are passed verbatim to the agent CLI after `--`
# (a single bare word with no leading dash is taken as the model, so
# `spawn-agent.sh dev-api <pane> sonnet` still works for kind claude).
# Env:
#   AGENT_KIND   kind for this worker (default $TEAM_KIND, else claude)
#   AGENT_ARGS   default args when none are passed positionally
#                (falls back to $TEAM_ARGS, which spawn-team.sh forwards)
#   AGENT_MODEL  model hint for kind claude's default args (default sonnet)
# Provider/config env is forwarded from the caller's own environment; see
# TEAM_ENV_* in agent-env.sh.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

require_deps
name="${1:?usage: spawn-agent.sh <name> <parent-pane-id> [agent-args...]}"
parent="${2:?usage: spawn-agent.sh <name> <parent-pane-id> [agent-args...]}"
shift 2
[[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "bad name: must match [a-z][a-z0-9_-]{0,31}"; exit 1; }

kind="${AGENT_KIND:-${TEAM_KIND:-claude}}"
model="${AGENT_MODEL:-sonnet}"
validate_kind "$kind"

if [ "$#" -eq 1 ] && [[ "$1" != -* ]]; then model="$1"; shift; fi
if [ "$#" -gt 0 ]; then
  AGENT_ARGV=("$@")
else
  resolve_agent_args AGENT "$kind" "${AGENT_ARGS:-${TEAM_ARGS:-}}" "$model"
fi

build_team_env

# ponytail: never forward the launching agent's own per-session vars
pane=$(herdr pane split "$parent" --direction down "${TEAM_ENV[@]}" | jq -r '.result.pane.pane_id')
start_agent "$name" "$pane" "$kind" "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}" >/dev/null
herdr agent wait "$name" --until idle --timeout 120000 >/dev/null \
  || echo "warn: $name not idle after 120s (check: herdr agent list)"

jq -n --arg name "$name" --arg pane "$pane" --arg kind "$kind" \
  --argjson args "$(printf '%s\n' "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}" | jq -R . | jq -sc .)" \
  '{name: $name, pane: $pane, kind: $kind, args: $args}'
