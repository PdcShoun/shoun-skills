#!/usr/bin/env bash
# Fire the final (or blocking) user notification exactly once per feature,
# even across PM restarts/resumes. Idempotency lives here — in a doc field a
# script checks and sets — instead of relying on the PM to remember whether
# it already notified.
#
# Usage: notify.sh <doc> <title> <body> [--sound none|done|request]
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

doc="${1:?usage: notify.sh <doc> <title> <body> [--sound none|done|request]}"
title="${2:?usage: notify.sh <doc> <title> <body> [--sound none|done|request]}"
body="${3:?usage: notify.sh <doc> <title> <body> [--sound none|done|request]}"
shift 3
sound="done"
[ "${1:-}" = "--sound" ] && sound="${2:-done}"

[ -f "$doc" ] || { echo "no such doc: $doc"; exit 1; }

already="$(doc_get_field "$doc" notified)"
if [ "$already" = "true" ]; then
  echo "already notified — skipping (doc: notified=true)"
  exit 0
fi

herdr notification show "$title" --body "$body" --sound "$sound"
doc_set_field "$doc" notified true
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
append_stage_log "$doc" "$ts [notify] sent: $title" || true
