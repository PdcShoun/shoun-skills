#!/usr/bin/env bash
# Spawn the feature-team starter agents (pm, sa, dev, tester, and optionally
# reviewer) in a fresh Herdr workspace.
# Usage: spawn-team.sh <slug>
#
# Agent kind (any kind herdr supports: pi, claude, codex, gemini, cursor, ...):
#   TEAM_KIND            kind for every role   (default: the CALLING agent's
#                         own kind — see detect_caller_kind in agent-env.sh;
#                         NEVER defaults to claude for a non-claude caller)
#   PM_KIND SA_KIND DEV_KIND TESTER_KIND REVIEWER_KIND    (default $TEAM_KIND)
# If TEAM_KIND is unset AND the caller's kind can't be detected AND a role has
# no explicit *_KIND/*_CONNECTION (nor one configured — see below), this
# script fails loudly instead of guessing — set TEAM_KIND (or
# FEATURE_TEAM_CALLER_KIND) explicitly. See feature-team/SKILL.md
# § Configuration precedence for the full chain.
#
# Agent CLI args, passed verbatim after `--`, whitespace-separated:
#   TEAM_ARGS            args for every role, unless overridden per role
#   PM_ARGS SA_ARGS DEV_ARGS TESTER_ARGS REVIEWER_ARGS
#   e.g. TEAM_KIND=codex TEAM_ARGS="--model gpt-5-codex --full-auto"
#
# Model selection (see feature-team/SKILL.md § Model selection and
# § Configuration scopes for the full precedence and rationale;
# model-registry.sh is the provider model table; config-lib.sh reads the
# user/repo config files):
#   PM_MODEL SA_MODEL DEV_MODEL TESTER_MODEL REVIEWER_MODEL
#     explicit model id — wins over everything below
#   PM_MODEL_PROFILE SA_MODEL_PROFILE DEV_MODEL_PROFILE TESTER_MODEL_PROFILE
#   REVIEWER_MODEL_PROFILE
#     semantic profile (top/strong/balanced/fast) per role
#   TEAM_MODEL_PROFILE   semantic profile for every role without its own override
#   PM_CONNECTION SA_CONNECTION DEV_CONNECTION TESTER_CONNECTION
#   REVIEWER_CONNECTION TEAM_CONNECTION
#     named connection (see ~/.config/feature-team/config.yaml's
#     `connections:`) to resolve a kind/provider from, instead of a bare kind
#   FEATURE_COMPLEXITY   simple|normal|complex|high-risk (default: repo
#                        config's `complexity:`, else "normal" — see
#                        config-lib.sh's effective_complexity)
#   REVIEWER_ENABLED     1/true to add a 5th Reviewer agent after Tester
#                        (default: repo config's `reviewer.enabled`, else off)
# With no explicit override at all, each role falls through: repo config
# (.feature-team/config.yaml) -> user config (~/.config/feature-team/
# config.yaml) -> caller inheritance -> built-in default profile. A role
# whose repo/user config names a connection that isn't defined in the user
# config fails immediately (MODEL_UNAVAILABLE) rather than silently trying
# another provider.
# Env forwarding to the team's panes: see TEAM_ENV_* in agent-env.sh.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

require_deps
slug="${1:?usage: spawn-team.sh <slug>}"

COMPLEXITY=$(effective_complexity)
WITH_REVIEWER=0
if reviewer_enabled; then WITH_REVIEWER=1; fi

ROLES="PM SA DEV TESTER"
[ "$WITH_REVIEWER" = 1 ] && ROLES="$ROLES REVIEWER"

# No associative arrays (bash 3.2, macOS's default /bin/bash, has none) —
# resolve_role_full's globals are stashed into per-role scalar vars named
# R_<ROLE>_<FIELD> via `printf -v` (indirect assignment; bash 3.1+), read
# back later the same way `resolve_model_profile` already does with
# `${!var}` (indirect expansion; bash 2+/POSIX-adjacent, used throughout
# this file already).
CALLER_KIND="$(detect_caller_kind || true)"

for role in $ROLES; do
  resolve_role_full "$role"
  [ -n "$RF_KIND" ] || fail_no_provider "TEAM_KIND"
  printf -v "R_${role}_KIND" '%s' "$RF_KIND"
  printf -v "R_${role}_CONNECTION" '%s' "$RF_CONNECTION"
  printf -v "R_${role}_PROVIDER" '%s' "$RF_PROVIDER"
  printf -v "R_${role}_PROFILE" '%s' "$RF_PROFILE"
  printf -v "R_${role}_MODEL" '%s' "$RF_MODEL"
  printf -v "R_${role}_SOURCE" '%s' "$RF_SOURCE"
done

# TEST_WORKER gets no pane of its own — Tester (the Tester Lead) spawns test
# workers dynamically, on demand, via spawn-test-worker.sh (feature-team/
# SKILL.md § Testing architecture) — but its resolved kind/model/profile is
# still recorded here and persisted into the feature doc's ```state block at
# kickoff, same as every other role, so a resumed feature and every worker
# it spawns later reuse this feature's own configuration rather than
# re-resolving against whatever the repo/user config says by then (§
# Feature-level model persistence).
resolve_role_full TEST_WORKER
[ -n "$RF_KIND" ] || fail_no_provider "TEAM_KIND"
R_TEST_WORKER_KIND="$RF_KIND"; R_TEST_WORKER_CONNECTION="$RF_CONNECTION"
R_TEST_WORKER_PROVIDER="$RF_PROVIDER"; R_TEST_WORKER_PROFILE="$RF_PROFILE"
R_TEST_WORKER_MODEL="$RF_MODEL"; R_TEST_WORKER_SOURCE="$RF_SOURCE"
validate_kind "$R_TEST_WORKER_KIND"

PM_KIND="$R_PM_KIND"; SA_KIND="$R_SA_KIND"; DEV_KIND="$R_DEV_KIND"; TESTER_KIND="$R_TESTER_KIND"
PM_MODEL="$R_PM_MODEL"; SA_MODEL="$R_SA_MODEL"; DEV_MODEL="$R_DEV_MODEL"; TESTER_MODEL="$R_TESTER_MODEL"
PM_PROFILE="$R_PM_PROFILE"; SA_PROFILE="$R_SA_PROFILE"; DEV_PROFILE="$R_DEV_PROFILE"; TESTER_PROFILE="$R_TESTER_PROFILE"
REVIEWER_KIND="${R_REVIEWER_KIND:-}"; REVIEWER_MODEL="${R_REVIEWER_MODEL:-}"; REVIEWER_PROFILE="${R_REVIEWER_PROFILE:-}"

PM_ARGS="${PM_ARGS:-${TEAM_ARGS:-}}"; SA_ARGS="${SA_ARGS:-${TEAM_ARGS:-}}"
DEV_ARGS="${DEV_ARGS:-${TEAM_ARGS:-}}"; TESTER_ARGS="${TESTER_ARGS:-${TEAM_ARGS:-}}"
REVIEWER_ARGS="${REVIEWER_ARGS:-${TEAM_ARGS:-}}"

for role in $ROLES; do
  kind_var="R_${role}_KIND"; validate_kind "${!kind_var}"
done

# Provider/model selection is diagnosable, not just correct — log it (no secrets).
team_log="[TEAM] caller=${CALLER_KIND:-unknown} pm=$PM_KIND sa=$SA_KIND dev=$DEV_KIND tester=$TESTER_KIND test_worker=$R_TEST_WORKER_KIND"
[ "$WITH_REVIEWER" = 1 ] && team_log+=" reviewer=$REVIEWER_KIND"
echo "$team_log" >&2
echo "[TEAM] complexity=$COMPLEXITY reviewer_enabled=$WITH_REVIEWER" >&2
for role in $ROLES TEST_WORKER; do
  conn_var="R_${role}_CONNECTION"; prov_var="R_${role}_PROVIDER"
  prof_var="R_${role}_PROFILE"; model_var="R_${role}_MODEL"; src_var="R_${role}_SOURCE"
  echo "[MODELS] $role conn=${!conn_var:-<none>} provider=${!prov_var:-<unknown>} profile=${!prof_var} model=${!model_var:-<provider-default>} source=${!src_var}" >&2
done

# Export the resolved (not just the user-supplied) kinds so build_team_env
# forwards them into every pane below. This matters even when TEAM_KIND was
# never set by the caller — e.g. a caller detected purely via CLAUDECODE or
# $FEATURE_TEAM_CALLER_KIND never exported TEAM_KIND itself, so without this,
# a pane running kind `pi` would have no signal of its own to re-detect "pi"
# from (there's no PI_-specific env marker), and a PM that later calls
# spawn-agent.sh/spawn-workstream.sh for a retry/resume/workstream would hit
# fail_no_provider instead of reusing the team's actual provider.
export TEAM_KIND PM_KIND SA_KIND DEV_KIND TESTER_KIND
export PM_MODEL SA_MODEL DEV_MODEL TESTER_MODEL
export PM_MODEL_PROFILE="$PM_PROFILE" SA_MODEL_PROFILE="$SA_PROFILE" \
       DEV_MODEL_PROFILE="$DEV_PROFILE" TESTER_MODEL_PROFILE="$TESTER_PROFILE"
[ -n "${CALLER_KIND:-}" ] && export FEATURE_TEAM_CALLER_KIND="$CALLER_KIND"
if [ "$WITH_REVIEWER" = 1 ]; then
  export REVIEWER_KIND REVIEWER_MODEL REVIEWER_MODEL_PROFILE="$REVIEWER_PROFILE"
fi
# TEST_WORKER gets no pane, but its resolved kind/model/profile is exported
# into the team's panes the same way — so Tester (the Tester Lead), which
# reads these back out when it calls spawn-test-worker.sh, spawns workers
# against this feature's own resolved configuration rather than re-deriving
# it against whatever the repo/user config says by the time it actually
# spawns one.
export TEST_WORKER_KIND="$R_TEST_WORKER_KIND" TEST_WORKER_MODEL="$R_TEST_WORKER_MODEL" \
       TEST_WORKER_MODEL_PROFILE="$R_TEST_WORKER_PROFILE"

# Agents of kind claude drive their teammates through the herdr skill — make
# sure it exists where they load skills (project .claude/skills or
# $CLAUDE_CONFIG_DIR/skills). Other kinds get the herdr commands inline in
# their briefing instead, so skip the install when no role is claude.
all_kinds=" $PM_KIND $SA_KIND $DEV_KIND $TESTER_KIND ${REVIEWER_KIND:-} "
case "$all_kinds" in
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
p5=""
[ "$WITH_REVIEWER" = 1 ] && p5=$(herdr pane split "$p4" --direction down "${TEAM_ENV[@]}" | jq -r '.result.pane.pane_id')

spawn() {   # <name> <pane> <kind> <args-var-name> <model>
  resolve_agent_args "${4%_ARGS}" "$3" "${!4:-}" "$5"
  start_agent "$1" "$2" "$3" "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}"
}
spawn pm     "$p1" "$PM_KIND"     PM_ARGS     "$PM_MODEL"
spawn sa     "$p2" "$SA_KIND"     SA_ARGS     "$SA_MODEL"
spawn dev    "$p3" "$DEV_KIND"    DEV_ARGS    "$DEV_MODEL"
spawn tester "$p4" "$TESTER_KIND" TESTER_ARGS "$TESTER_MODEL"
[ "$WITH_REVIEWER" = 1 ] && spawn reviewer "$p5" "$REVIEWER_KIND" REVIEWER_ARGS "$REVIEWER_MODEL"

wait_for="pm sa dev tester"
[ "$WITH_REVIEWER" = 1 ] && wait_for="$wait_for reviewer"
for a in $wait_for; do
  herdr agent wait "$a" --until idle --timeout 120000 >/dev/null \
    || echo "warn: $a not idle after 120s (check: herdr agent list)"
done

role_field_json() {   # <field: KIND|CONNECTION|PROVIDER|PROFILE|MODEL|SOURCE>
  local field="$1" role val var out=()
  for role in PM SA DEV TESTER TEST_WORKER REVIEWER; do
    [ "$role" = REVIEWER ] && [ "$WITH_REVIEWER" != 1 ] && continue
    var="R_${role}_${field}"; val="${!var:-}"
    out+=("$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')" "$val")
  done
  printf '%s\n' "${out[@]}" | jq -R . | jq -sc '[ . as $a | range(0; length; 2) | {key: $a[.], value: (if $a[.+1] == "" then null else $a[.+1] end)} ] | from_entries'
}

jq -n --arg ws "$ws" --arg dir "$here" --arg default_branch "$(detect_default_branch)" \
  --arg p1 "$p1" --arg p2 "$p2" --arg p3 "$p3" --arg p4 "$p4" --arg p5 "$p5" \
  --arg caller "${CALLER_KIND:-}" --arg complexity "$COMPLEXITY" \
  --argjson with_reviewer "$([ "$WITH_REVIEWER" = 1 ] && echo true || echo false)" \
  --argjson kinds "$(role_field_json KIND)" \
  --argjson connections "$(role_field_json CONNECTION)" \
  --argjson providers "$(role_field_json PROVIDER)" \
  --argjson model_profiles "$(role_field_json PROFILE)" \
  --argjson models "$(role_field_json MODEL)" \
  --argjson sources "$(role_field_json SOURCE)" \
  --argjson role_skills "$(role_skills_json)" \
  '{workspace: $ws, skill_dir: $dir, default_branch: $default_branch,
    panes: (if $p5 == "" then {pm: $p1, sa: $p2, dev: $p3, tester: $p4}
            else {pm: $p1, sa: $p2, dev: $p3, tester: $p4, reviewer: $p5} end),
    caller_kind: (if $caller == "" then null else $caller end),
    complexity: $complexity, reviewer_enabled: $with_reviewer,
    kinds: $kinds, connections: $connections, providers: $providers,
    model_profiles: $model_profiles, models: $models, sources: $sources,
    role_skills: $role_skills,
    agents: (if $with_reviewer then ["pm", "sa", "dev", "tester", "reviewer"] else ["pm", "sa", "dev", "tester"] end)}'
