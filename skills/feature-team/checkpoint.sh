#!/usr/bin/env bash
# Record one checkpoint against a feature doc: a Stage log line plus any
# ```state field updates, in one atomic, consistently-formatted call. This
# exists so "every transition must be recorded" is a script contract, not
# something an LLM has to remember to format the same way every time.
#
# Usage:
#   checkpoint.sh <doc> "<stage message>" [--set key=value ...] [--comment]
#
# --comment mirrors the stage message as a `gh issue comment` on the doc's
# recorded `issue:` field (only if `gh` is available and an issue number is
# set) — use it for checkpoints worth surfacing to the user, not every one.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

doc="${1:?usage: checkpoint.sh <doc> \"<message>\" [--set key=value ...] [--comment]}"
message="${2:?usage: checkpoint.sh <doc> \"<message>\" [--set key=value ...] [--comment]}"
shift 2
[ -f "$doc" ] || { echo "no such doc: $doc"; exit 1; }

stage="$(doc_get_field "$doc" current_stage)"
comment=0
sets=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --set) sets+=("$2"); shift 2 ;;
    --comment) comment=1; shift ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
append_stage_log "$doc" "$ts [${stage:-?}] $message"
doc_set_field "$doc" last_checkpoint "$ts"
for kv in "${sets[@]+"${sets[@]}"}"; do
  k="${kv%%=*}"; v="${kv#*=}"
  doc_set_field "$doc" "$k" "$v"
done

if [ "$comment" = 1 ] && command -v gh >/dev/null; then
  issue="$(doc_get_field "$doc" issue)"
  if [ -n "$issue" ] && [ "$issue" != "null" ]; then
    gh issue comment "$issue" --body "$ts — $message" >/dev/null 2>&1 \
      || echo "warn: gh issue comment failed (network/auth?) — doc updated regardless" >&2
  fi
fi

echo "checkpoint recorded: $message"
