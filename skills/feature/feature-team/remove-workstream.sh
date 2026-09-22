#!/usr/bin/env bash
# Safely tear down a workstream worktree created by spawn-workstream.sh.
# Refuses to remove a worktree that still has uncommitted changes or commits
# not reachable from --into, unless --force is given — this is the guard
# against ever discarding a worker's unfinished or unmerged work.
#
# Usage: remove-workstream.sh <workspace-id> [--into <ref>] [--force]
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

require_deps
ws="${1:?usage: remove-workstream.sh <workspace-id> [--into <ref>] [--force]}"
shift
into=""
force=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --into) into="$2"; shift 2 ;;
    --force) force=1; shift ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

info=$(herdr workspace get "$ws")
path=$(jq -r '.result.workspace.worktree.checkout_path // empty' <<<"$info")
[ -n "$path" ] || { echo "workspace $ws has no linked worktree — nothing to remove"; exit 1; }
branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

if [ "$force" != 1 ]; then
  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    echo "refusing to remove: $path has uncommitted changes (use --force to discard, or commit/stash first)"
    exit 1
  fi
  if [ -n "$into" ] && [ -n "$branch" ]; then
    unmerged=$(git -C "$path" rev-list --count "$into..$branch" 2>/dev/null || echo "?")
    if [ "$unmerged" != "0" ]; then
      echo "refusing to remove: branch '$branch' has $unmerged commit(s) not in '$into' (use --force once merged/pushed, or pass --into correctly)"
      exit 1
    fi
  fi
fi

force_flag=()
[ "$force" = 1 ] && force_flag=(--force)
herdr worktree remove --workspace "$ws" "${force_flag[@]}" --trust-repository
