#!/usr/bin/env bash
# Spawn one parallel test worker for the Tester Lead's verification plan
# (feature-team/SKILL.md § Testing architecture). This is the sanctioned way
# the Tester Lead spawns a worker — it resolves the `test_worker` role's
# kind/connection/provider/profile/model through the exact same chain every
# other role uses (agent-env.sh's resolve_role_full — never a hardcoded
# model, never a silent provider switch), defaulting to the `fast` profile,
# then delegates the actual spawn to spawn-agent.sh (the common case: a
# read-only or sequential-within-its-own-scope worker sharing the parent's
# tree) or, with --worktree, to spawn-workstream.sh (a worker that must write
# test files and needs isolation from another concurrently-running worker —
# feature-team/SKILL.md § Parallel workers and Git safety).
#
# Usage:
#   spawn-test-worker.sh <name> <parent-pane-id> [worker-args...]
#   spawn-test-worker.sh <name> --worktree <branch> [--base <ref>] [worker-args...]
#
# Env (same precedence as any other role — feature-team/SKILL.md
# § Configuration precedence):
#   TEST_WORKER_KIND / TEST_WORKER_CONNECTION / TEST_WORKER_MODEL /
#   TEST_WORKER_MODEL_PROFILE   explicit per-worker-type override; falls
#     through to repo config (roles.test_worker.*), user config
#     (defaults.roles.test_worker.*), caller inheritance, then the built-in
#     "fast" default (see agent-env.sh's role_default_profile)
#   AGENT_KIND / AGENT_MODEL / AGENT_MODEL_PROFILE   set automatically from
#     the resolution above before delegating — do not set these yourself,
#     they will be overwritten
#
# The Tester Lead is still responsible for:
#   - deciding whether spawning is even worth it (feature-team/SKILL.md
#     § Scaling rules) and respecting testing.parallel.max_workers
#   - giving the worker a narrow, bounded scope (its own prompt, via
#     `herdr agent prompt <name> "<task>" --wait --timeout <ms>`)
#   - using this worker's own `testing.timeout.<stage>` (see config-lib.sh's
#     testing_timeout_ms) as that --timeout
#   - releasing the worker when it's done (`herdr pane close <pane>` for a
#     shared-tree worker; `remove-workstream.sh` for a --worktree one — see
#     feature-team/SKILL.md § Agent lifecycle)
#
# Output: spawn-agent.sh's or spawn-workstream.sh's JSON, plus
# `role`, `profile`, and `worker_timeout_ms` (this worker's resolved
# testing.timeout.worker, in case its task doesn't map to a more specific
# smoke/unit/integration/e2e stage).
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

require_deps
name="${1:?usage: spawn-test-worker.sh <name> <parent-pane-id>|--worktree <branch> [args...]}"
shift

resolve_role_full TEST_WORKER
[ -n "$RF_KIND" ] || fail_no_provider "TEST_WORKER_KIND"
export AGENT_KIND="$RF_KIND"
export AGENT_MODEL="$RF_MODEL"
export AGENT_MODEL_PROFILE="$RF_PROFILE"

worker_timeout_ms=$(testing_timeout_ms worker)

if [ "${1:-}" = "--worktree" ]; then
  shift
  branch="${1:?--worktree needs a branch name}"; shift
  base_args=()
  if [ "${1:-}" = "--base" ]; then base_args=(--base "$2"); shift 2; fi
  result=$(bash "$here/spawn-workstream.sh" "$name" "$branch" "${base_args[@]}" --label "test-$name" "$@")
else
  parent="${1:?usage: spawn-test-worker.sh <name> <parent-pane-id> [args...]}"; shift
  result=$(bash "$here/spawn-agent.sh" "$name" "$parent" "$@")
fi

jq --arg role test_worker --arg profile "$RF_PROFILE" --argjson worker_timeout_ms "$worker_timeout_ms" \
  '. + {role: $role, profile: $profile, worker_timeout_ms: $worker_timeout_ms}' <<<"$result"
