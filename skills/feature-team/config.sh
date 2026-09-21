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
  local roles="PM SA DEV TESTER"
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
  for role in PM SA DEV TESTER; do
    resolve_role_full "$role"
    body+="  $(printf '%s' "$role" | tr '[:upper:]' '[:lower:]'):"$'\n'
    [ -n "$RF_CONNECTION" ] && body+="    connection: $RF_CONNECTION"$'\n'
    [ -n "$RF_PROVIDER" ] && body+="    provider: $RF_PROVIDER"$'\n'
    body+="    profile: $RF_PROFILE"$'\n'
    [ -n "$RF_MODEL" ] && body+="    model: $RF_MODEL"$'\n'
  done

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
