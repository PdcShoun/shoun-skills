#!/usr/bin/env bash
# feature-team's configuration CLI — introspection and the explicit
# "remember this repo's model setup" operation (see feature-team/SKILL.md
# § Configuration display and § Explicit "remember" behavior).
#
# Usage:
#   config.sh show                    print the effective per-role config
#   config.sh save                    persist the effective config to
#   config.sh remember-models         .feature-team/config.yaml (aliases of
#                                      the same operation)
#
# Neither subcommand requires Herdr or a live agent — this is pure
# introspection over the same resolver spawn-team.sh uses
# (agent-env.sh's resolve_role_full), so it reflects exactly what a
# `spawn-team.sh` run would actually start, without starting anything.
#
# Never prints or writes secrets: the only fields involved are role,
# connection name, provider name, profile name, and model id — never an API
# key, token, or credential (feature-team/SKILL.md § Repository config
# should not contain secrets).
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=agent-env.sh
. "$here/agent-env.sh"

command -v jq >/dev/null || { echo "jq required"; exit 1; }

usage() {
  echo "usage: config.sh <show|save|remember-models>" >&2
  exit 1
}

cmd="${1:-show}"

active_roles() {
  local roles="PM SA DEV TESTER TEST_WORKER"
  reviewer_enabled && roles="$roles REVIEWER"
  echo "$roles"
}

cmd_show() {
  local role complexity roles ucfg rcfg ucfg_note="" rcfg_note=""
  complexity=$(effective_complexity)
  roles=$(active_roles)
  ucfg=$(user_config_path); rcfg=$(repo_config_path)
  [ -f "$ucfg" ] || ucfg_note=" (not found)"
  [ -f "$rcfg" ] || rcfg_note=" (not found)"

  echo "Repository: $(repo_root)"
  echo "User config: ${ucfg}${ucfg_note}"
  echo "Repo config: ${rcfg}${rcfg_note}"
  echo "Complexity: $complexity"
  if reviewer_enabled; then echo "Reviewer: enabled"; else echo "Reviewer: disabled"; fi
  echo
  printf '%-10s %-12s %-10s %-10s %-28s %-10s\n' "Role" "Connection" "Provider" "Profile" "Model" "Source"
  for role in $roles; do
    resolve_role_full "$role"
    printf '%-10s %-12s %-10s %-10s %-28s %-10s\n' \
      "$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')" \
      "${RF_CONNECTION:--}" "${RF_PROVIDER:--}" "$RF_PROFILE" "${RF_MODEL:-<provider-default>}" "$RF_SOURCE"
  done
  echo
  echo "Testing (Tester Lead's parallel-verification policy — feature-team/SKILL.md § Testing configuration):"
  printf '  parallel: enabled=%s max_workers=%s min_parallel_tasks=%s\n' \
    "$(testing_parallel_enabled)" "$(testing_max_workers)" "$(testing_min_parallel_tasks)"
  printf '  strategy: smoke_first=%s parallel_independent_checks=%s early_failure_feedback=%s\n' \
    "$(testing_strategy_enabled smoke_first)" "$(testing_strategy_enabled parallel_independent_checks)" \
    "$(testing_strategy_enabled early_failure_feedback)"
  printf '            dependency_aware_cancellation=%s e2e_when_required=%s final_regression=%s\n' \
    "$(testing_strategy_enabled dependency_aware_cancellation)" "$(testing_strategy_enabled e2e_when_required)" \
    "$(testing_strategy_enabled final_regression)"
  printf '  retry:    max_attempts=%s\n' "$(testing_retry_max_attempts)"
  printf '  timeout:  smoke=%sms unit=%sms integration=%sms e2e=%sms worker=%sms\n' \
    "$(testing_timeout_ms smoke)" "$(testing_timeout_ms unit)" "$(testing_timeout_ms integration)" \
    "$(testing_timeout_ms e2e)" "$(testing_timeout_ms worker)"
}

# Emits the fixed-shape repo config document directly (never round-tripped
# through the yaml_get/yaml_keys reader — see config-lib.sh's header for why
# a generic YAML writer isn't needed here).
cmd_save() {
  local role complexity roles path ts body reviewer_block=""
  complexity=$(effective_complexity)
  roles=$(active_roles)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  path=$(repo_config_path)
  mkdir -p "$(dirname "$path")"

  body="version: 1"$'\n\n'"complexity: $complexity"$'\n'

  if reviewer_enabled; then
    resolve_role_full REVIEWER
    reviewer_block="reviewer:"$'\n'"  enabled: true"$'\n'"  profile: $RF_PROFILE"$'\n'
  else
    reviewer_block="reviewer:"$'\n'"  enabled: false"$'\n'
  fi
  body+=$'\n'"$reviewer_block"

  body+=$'\n'"roles:"$'\n'
  for role in PM SA DEV TESTER TEST_WORKER; do
    resolve_role_full "$role"
    body+="  $(printf '%s' "$role" | tr '[:upper:]' '[:lower:]'):"$'\n'
    [ -n "$RF_CONNECTION" ] && body+="    connection: $RF_CONNECTION"$'\n'
    [ -n "$RF_PROVIDER" ] && body+="    provider: $RF_PROVIDER"$'\n'
    body+="    profile: $RF_PROFILE"$'\n'
    [ -n "$RF_MODEL" ] && body+="    model: $RF_MODEL"$'\n'
  done

  body+=$'\n'"testing:"$'\n'
  body+="  parallel:"$'\n'
  body+="    enabled: $(testing_parallel_enabled)"$'\n'
  body+="    max_workers: $(testing_max_workers)"$'\n'
  body+="    min_parallel_tasks: $(testing_min_parallel_tasks)"$'\n'
  body+="  strategy:"$'\n'
  body+="    smoke_first: $(testing_strategy_enabled smoke_first)"$'\n'
  body+="    parallel_independent_checks: $(testing_strategy_enabled parallel_independent_checks)"$'\n'
  body+="    early_failure_feedback: $(testing_strategy_enabled early_failure_feedback)"$'\n'
  body+="    dependency_aware_cancellation: $(testing_strategy_enabled dependency_aware_cancellation)"$'\n'
  body+="    e2e_when_required: $(testing_strategy_enabled e2e_when_required)"$'\n'
  body+="    final_regression: $(testing_strategy_enabled final_regression)"$'\n'
  body+="  retry:"$'\n'
  body+="    max_attempts: $(testing_retry_max_attempts)"$'\n'
  body+="  timeout:"$'\n'
  body+="    smoke: $(testing_timeout_ms smoke)ms"$'\n'
  body+="    unit: $(testing_timeout_ms unit)ms"$'\n'
  body+="    integration: $(testing_timeout_ms integration)ms"$'\n'
  body+="    e2e: $(testing_timeout_ms e2e)ms"$'\n'
  body+="    worker: $(testing_timeout_ms worker)ms"$'\n'

  body+=$'\n'"model_policy:"$'\n'"  source: repository"$'\n'"  updated_at: \"$ts\""$'\n'

  printf '%s' "$body" > "$path"

  echo "Saved effective model configuration to $path:"
  echo
  cmd_show
}

case "$cmd" in
  show) cmd_show ;;
  save|remember-models) cmd_save ;;
  -h|--help) usage ;;
  *) echo "unknown subcommand: $cmd"; usage ;;
esac
