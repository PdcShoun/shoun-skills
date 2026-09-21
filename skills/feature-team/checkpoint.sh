#!/usr/bin/env bash
# Record one Progress Log stamp against a feature doc (see
# templates/feature-doc.md for the exact stamp shape) plus any ```state
# field updates, in one atomic, consistently-formatted call. This exists so
# "the Progress Log is a concise, structured timeline, not a transcript" is a
# script contract, not something an LLM has to remember to format the same
# way every time.
#
# Usage:
#   checkpoint.sh <doc> <STAGE> <STATUS> --summary "<1-2 sentences>" \
#     [--evidence "<item>"]... [--pm-verify "<item>"]... \
#     --result "<current outcome>" [--next "<next action>"] \
#     [--set key=value ...] [--comment]
#
# STAGE:  PM SA DEV TESTER GIT CI PR SYSTEM
# STATUS: STARTED PLANNED IN_PROGRESS PASS FAIL BLOCKED CHANGES_REQUESTED
#         READY RETRY RESUMED DONE
# Other values are accepted with a warning rather than rejected outright —
# but reuse one of the above unless nothing genuinely fits; do not invent a
# new status just to describe this stamp more precisely (feature-pm).
#
# --summary and --result are always required. --next is required unless
# STATUS is DONE (every non-terminal stamp needs a concrete next action).
# --evidence/--pm-verify may repeat; each becomes one bullet. Keep --summary
# to 1-2 sentences and put detail in --evidence, or better, in a separate
# report file referenced from --evidence — never paste a worker's full
# report into this call.
#
# Idempotent: an identical (stage, status, summary, result) tuple is not
# logged twice (see agent-env.sh's append_progress_entry) — safe to call
# again after a retry/replay/resume. ```state fields are still applied even
# when the log entry itself is deduped.
#
# --comment mirrors the stamp as a comment on the doc's recorded `issue:`
# field (only if a supported forge CLI is available and an issue number is
# set) — use it for checkpoints worth surfacing to the user, not every one.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"
# shellcheck source=vcs.sh
. "$here/vcs.sh"

usage() {
  cat >&2 <<'EOF'
usage: checkpoint.sh <doc> <STAGE> <STATUS> --summary "..." \
         [--evidence "..."]... [--pm-verify "..."]... \
         --result "..." [--next "..."] [--set key=value ...] [--comment]
EOF
  exit 1
}

doc="${1:-}"; stage="${2:-}"; status="${3:-}"
[ -n "$doc" ] && [ -n "$stage" ] && [ -n "$status" ] || usage
shift 3
[ -f "$doc" ] || { echo "no such doc: $doc"; exit 1; }

stage="$(printf '%s' "$stage" | tr '[:lower:]' '[:upper:]')"
status="$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')"

case " PM SA DEV TESTER GIT CI PR SYSTEM " in
  *" $stage "*) ;;
  *) echo "warn: '$stage' is not one of the standard stages (PM SA DEV TESTER GIT CI PR SYSTEM) — using it anyway" >&2 ;;
esac
case " STARTED PLANNED IN_PROGRESS PASS FAIL BLOCKED CHANGES_REQUESTED READY RETRY RESUMED DONE " in
  *" $status "*) ;;
  *) echo "warn: '$status' is not one of the standard statuses — using it anyway" >&2 ;;
esac

summary="" result="" next="" comment=0
evidence_lines=() pmverify_lines=() sets=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary)  summary="${2:?--summary needs a value}"; shift 2 ;;
    --evidence) evidence_lines+=("${2:?--evidence needs a value}"); shift 2 ;;
    --pm-verify) pmverify_lines+=("${2:?--pm-verify needs a value}"); shift 2 ;;
    --result)   result="${2:?--result needs a value}"; shift 2 ;;
    --next)     next="${2:?--next needs a value}"; shift 2 ;;
    --set)      sets+=("${2:?--set needs key=value}"); shift 2 ;;
    --comment)  comment=1; shift ;;
    *) echo "unknown arg: $1"; usage ;;
  esac
done

[ -n "$summary" ] || { echo "checkpoint.sh: --summary is required"; usage; }
[ -n "$result" ]  || { echo "checkpoint.sh: --result is required"; usage; }
if [ "$status" != "DONE" ] && [ -z "$next" ]; then
  echo "checkpoint.sh: --next is required unless STATUS is DONE (this stamp is $status)"; usage
fi

evidence=""
for e in "${evidence_lines[@]+"${evidence_lines[@]}"}"; do evidence+="- $e"$'\n'; done
evidence="${evidence%$'\n'}"
pmverify=""
for p in "${pmverify_lines[@]+"${pmverify_lines[@]}"}"; do pmverify+="- $p"$'\n'; done
pmverify="${pmverify%$'\n'}"

logged=1
append_progress_entry "$doc" "$stage" "$status" "$summary" "$evidence" "$pmverify" "$result" "$next" || logged=0

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
doc_set_field "$doc" last_checkpoint "$ts"
for kv in "${sets[@]+"${sets[@]}"}"; do
  k="${kv%%=*}"; v="${kv#*=}"
  doc_set_field "$doc" "$k" "$v"
done

if [ "$comment" = 1 ] && [ "$logged" = 1 ] && vcs_available; then
  issue="$(doc_get_field "$doc" issue)"
  if [ -n "$issue" ] && [ "$issue" != "null" ]; then
    body="**$stage → $status**"$'\n\n'"$summary"$'\n\n'"Result: $result"
    vcs_issue_comment "$issue" "$body" >/dev/null 2>&1 \
      || echo "warn: issue comment failed (network/auth?) — doc updated regardless" >&2
  fi
fi

if [ "$logged" = 1 ]; then
  echo "checkpoint recorded: $stage → $status"
else
  echo "checkpoint deduped (state fields updated, no new log entry): $stage → $status"
fi
