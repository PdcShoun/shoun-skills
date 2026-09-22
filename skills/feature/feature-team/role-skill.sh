#!/usr/bin/env bash
# Print the absolute path of a feature-team role contract, so a prompt can
# tell an agent "read this file first" without anyone hardcoding a layout.
#
# Usage:
#   role-skill.sh <pm|sa|dev|tester|reviewer|handoff|git|security>   # one path
#   role-skill.sh --json                                             # all, as JSON
#
# Exits 1 with a message if the requested skill is not installed — a missing
# contract must be visible, not silently skipped. Needed on resume too: a
# respawned PM re-derives these paths instead of relying on a prompt it no
# longer has.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

arg="${1:?usage: role-skill.sh <pm|sa|dev|tester|reviewer|handoff|git|security> | --json}"

if [ "$arg" = "--json" ]; then
  command -v jq >/dev/null || { echo "jq required for --json"; exit 1; }
  role_skills_json
  exit 0
fi

case " $ROLE_SKILLS " in
  *" $arg "*) ;;
  *) echo "unknown role '$arg' (known: $ROLE_SKILLS)"; exit 1 ;;
esac

role_skill_path "feature-$arg" || {
  echo "skill 'feature-$arg' not installed — looked next to $here, in" \
       "$PWD/.claude/skills, and in ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
  exit 1
}
