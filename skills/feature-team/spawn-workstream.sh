#!/usr/bin/env bash
# Spawn a worker for an INDEPENDENT parallel workstream in its own Git
# worktree + Herdr workspace, so it never shares a working tree with the PM
# or with any other concurrently-running workstream. Use this instead of
# spawn-agent.sh whenever more than one code-writing agent will run at the
# same time — spawn-agent.sh's panes all share one working tree and are only
# safe for sequential or read-only helpers.
#
# Usage: spawn-workstream.sh <name> <branch> [--base <ref>] [--label <text>] [-- <agent-args...>]
#
# Resume-safe: if <branch> already has a worktree (open or on disk), this
# reopens/reuses it instead of creating a duplicate branch/worktree/pane —
# see `herdr worktree open`/`create` semantics. If a live agent named <name>
# is already running in that worktree's pane (herdr server survived a PM
# crash), it is left alone rather than double-started.
#
# Env (same meaning as spawn-agent.sh):
#   AGENT_KIND   kind for this worker (default $TEAM_KIND, else claude)
#   AGENT_ARGS   default args when none passed positionally (falls back to $TEAM_ARGS)
#   AGENT_MODEL  model hint for kind claude's default args (default sonnet)
# Provider/config env is forwarded from the caller's environment (see
# TEAM_ENV_* in agent-env.sh) via `pane run` + `export`, because
# `herdr worktree create/open` has no `--env` flag.
#
# Output: {name, workspace, pane, branch, worktree, kind, args, mode}
# mode is "created" (new worktree), "reopened" (existing worktree, pane was
# empty), or "already-running" (existing worktree, agent still alive there).
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

require_deps
command -v git >/dev/null || { echo "git required"; exit 1; }
# bare `herdr worktree` is a usage message and exits nonzero — that is expected
wt_groups=$(herdr worktree 2>&1) || true
case "$wt_groups" in
  *"herdr worktree create"*) ;;
  *) echo "this herdr build has no 'worktree' command group — cannot isolate" \
          "workstreams; fall back to spawn-agent.sh (shared tree, sequential only)"
     exit 1 ;;
esac

name="${1:?usage: spawn-workstream.sh <name> <branch> [--base <ref>] [--label <text>] [-- agent-args...]}"
branch="${2:?usage: spawn-workstream.sh <name> <branch> [--base <ref>] [--label <text>] [-- agent-args...]}"
shift 2
[[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "bad name: must match [a-z][a-z0-9_-]{0,31}"; exit 1; }

base=""
label="$name"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ -n "$base" ] || base=$(detect_default_branch)

kind="${AGENT_KIND:-${TEAM_KIND:-claude}}"
model="${AGENT_MODEL:-sonnet}"
validate_kind "$kind"

if [ "$#" -eq 1 ] && [[ "$1" != -* ]]; then model="$1"; shift; fi
if [ "$#" -gt 0 ]; then
  AGENT_ARGV=("$@")
else
  resolve_agent_args AGENT "$kind" "${AGENT_ARGS:-${TEAM_ARGS:-}}" "$model"
fi

# The repo this script must act on: wherever it's actually invoked from, not
# wherever $HERDR_WORKSPACE_ID happens to point (see below).
expected_root=$(git rev-parse --show-toplevel 2>/dev/null) \
  || { echo "must be run from inside the target git repo"; exit 1; }
expected_root=$(git -C "$expected_root" rev-parse --show-toplevel)

# ponytail: sequential herdr calls, no retries — herdr errors bubble up as-is.
# Idempotent open-then-create: reuse whatever already exists for this branch.
spawn_worktree() {   # <location-flag...>
  if result=$(herdr worktree open "$@" --branch "$branch" --label "$label" --no-focus --trust-repository 2>/dev/null); then
    mode="reopened"
  else
    result=$(herdr worktree create "$@" --branch "$branch" --base "$base" --label "$label" --no-focus --trust-repository)
    mode="created"
  fi
}

# Prefer --workspace (the caller's own, already-registered workspace) over
# --cwd: --cwd on a repo herdr hasn't seen before silently opens an extra
# plain workspace as a side effect, cluttering the user's session. But
# $HERDR_WORKSPACE_ID names whatever workspace the CALLING pane happens to
# live in — if that workspace was opened against a different repo (e.g. this
# script is invoked from a coordinator pane that doesn't share the feature's
# own workspace), --workspace would silently create the branch/worktree in
# the WRONG repo. Verify the resolved repo before trusting the result; fall
# back to --cwd (accepting its minor side effect) on any mismatch.
mode=""; result=""
if [ -n "${HERDR_WORKSPACE_ID:-}" ]; then
  spawn_worktree --workspace "$HERDR_WORKSPACE_ID"
  got_root=$(jq -r '.result.workspace.worktree.repo_root // empty' <<<"$result")
  if [ -z "$got_root" ] || [ "$(git -C "$got_root" rev-parse --show-toplevel 2>/dev/null)" != "$expected_root" ]; then
    echo "warn: \$HERDR_WORKSPACE_ID ($HERDR_WORKSPACE_ID) resolved to a different repo than $PWD — discarding that result and retrying with --cwd" >&2
    if [ "$mode" = "created" ]; then
      bad_ws=$(jq -r '.result.workspace.workspace_id' <<<"$result")
      herdr worktree remove --workspace "$bad_ws" --force --trust-repository >/dev/null 2>&1 || true
    fi
    mode=""; result=""
  fi
fi
[ -n "$mode" ] || spawn_worktree --cwd "$PWD"

new_ws=$(jq -r '.result.workspace.workspace_id' <<<"$result")
pane=$(jq -r '.result.root_pane.pane_id' <<<"$result")
path=$(jq -r '.result.worktree.path' <<<"$result")

if herdr agent get "$name" >/dev/null 2>&1; then
  mode="already-running"
else
  build_team_env
  if [ "${#TEAM_ENV[@]}" -gt 0 ]; then
    export_cmd=$(team_env_export_cmd)
    sentinel="__team_env_ready_$$__"
    herdr pane run "$pane" "${export_cmd}echo $sentinel" >/dev/null
    herdr pane wait-output "$pane" --match "$sentinel" --timeout 15000 >/dev/null \
      || echo "warn: env export in $name's pane did not confirm within 15s" >&2
  fi
  start_agent "$name" "$pane" "$kind" "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}" >/dev/null
  herdr agent wait "$name" --until idle --timeout 120000 >/dev/null \
    || echo "warn: $name not idle after 120s (check: herdr agent list)"
fi

jq -n --arg name "$name" --arg workspace "$new_ws" --arg pane "$pane" \
  --arg kind "$kind" --arg branch "$branch" --arg path "$path" --arg mode "$mode" \
  --argjson args "$(printf '%s\n' "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}" | jq -R . | jq -sc .)" \
  '{name: $name, workspace: $workspace, pane: $pane, kind: $kind, branch: $branch, worktree: $path, mode: $mode, args: $args}'
