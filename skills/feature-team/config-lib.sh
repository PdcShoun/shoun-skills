#!/usr/bin/env bash
# Reader for feature-team's two YAML configuration scopes (see
# feature-team/SKILL.md § Configuration scopes):
#   user config  ~/.config/feature-team/config.yaml   (global defaults)
#   repo config  <repo root>/.feature-team/config.yaml (per-repository)
# (the third scope, feature-level persistence, lives in
# docs/features/<slug>.md's ```state block via agent-env.sh's
# doc_get_field/doc_set_field — not here.)
#
# This is NOT a general YAML parser — it supports exactly one shape: nested
# 2-space-indented maps of scalar `key: value` pairs. No lists, no multi-line
# scalars, no anchors/aliases, no flow style. That is all these files ever
# need (see the schema examples in SKILL.md § Configuration scopes), and
# staying inside that subset means feature-team has no dependency on
# yq/PyYAML/ruamel — none of which are guaranteed present in a herdr pane of
# an arbitrary agent kind. Writing a config file (config.sh's `save`) never
# round-trips through this reader — it always emits the fixed known shape
# directly, so there is no generic-YAML-writer problem to solve either.
#
# Every getter is silent (empty stdout, exit 0) when the file or path is
# missing — "not configured" is not an error at this layer; callers decide
# what an absence means (fall through to the next scope, or fail loudly for
# a specifically-referenced-but-undefined connection — see
# resolve_role_kind's MODEL_UNAVAILABLE path in agent-env.sh).

USER_CONFIG_PATH="${FEATURE_TEAM_USER_CONFIG:-$HOME/.config/feature-team/config.yaml}"

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

repo_config_path() {
  printf '%s/.feature-team/config.yaml' "$(repo_root)"
}

repo_config_local_path() {
  printf '%s/.feature-team/config.local.yaml' "$(repo_root)"
}

user_config_path() {
  printf '%s' "$USER_CONFIG_PATH"
}

# yaml_get <file> <dotted.path> — prints the scalar at that path (last one
# wins if a key repeats, matching normal YAML-map semantics), or nothing.
yaml_get() {
  local file="$1" path="$2"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk -v target="$path" '
    BEGIN { n = split(target, want, ".") }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    {
      line = $0
      sub(/\r$/, "", line)
      indent = 0; s = line
      while (substr(s, 1, 1) == " ") { indent++; s = substr(s, 2) }
      if (length(s) == 0) next
      depth = int(indent / 2)
      colon = index(s, ":")
      if (colon == 0) next
      key = substr(s, 1, colon - 1)
      val = substr(s, colon + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (val !~ /^"/ && val !~ /^\x27/) { sub(/[ \t]+#.*$/, "", val) }
      gsub(/^"|"$/, "", val)
      gsub(/^\x27|\x27$/, "", val)
      stack[depth] = key
      for (i = depth + 1; i in stack; i++) delete stack[i]
      if (val == "") next
      if (depth + 1 != n) next
      ok = 1
      for (i = 0; i < n; i++) if (stack[i] != want[i + 1]) { ok = 0; break }
      if (ok) { found = val }
    }
    END { if (found != "") print found }
  ' "$file"
}

# yaml_keys <file> <dotted.path-of-parent, "" for top level> — prints the
# immediate child keys of a mapping node, one per line, in file order.
yaml_keys() {
  local file="$1" path="$2"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk -v target="$path" '
    BEGIN { n = (target == "" ? 0 : split(target, want, ".")) }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    {
      line = $0
      sub(/\r$/, "", line)
      indent = 0; s = line
      while (substr(s, 1, 1) == " ") { indent++; s = substr(s, 2) }
      if (length(s) == 0) next
      depth = int(indent / 2)
      colon = index(s, ":")
      if (colon == 0) next
      key = substr(s, 1, colon - 1)
      val = substr(s, colon + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (depth == n) {
        ok = 1
        for (i = 0; i < n; i++) if (stack[i] != want[i + 1]) { ok = 0; break }
        if (ok && val == "") print key
      }
      stack[depth] = key
      for (i = depth + 1; i in stack; i++) delete stack[i]
    }
  ' "$file"
}

# Convenience wrappers — these are the only two scopes anything outside this
# file should ever read from directly.
cfg_get_repo() { yaml_get "$(repo_config_path)" "$1"; }
cfg_get_user() { yaml_get "$(user_config_path)" "$1"; }
cfg_keys_repo() { yaml_keys "$(repo_config_path)" "$1"; }
cfg_keys_user() { yaml_keys "$(user_config_path)" "$1"; }

# ---- Connections ---------------------------------------------------------
# Connections are defined ONLY in the user-level config — they name a
# specific account/CLI setup on THIS machine (see SKILL.md § Connection vs
# Provider). A repository references a connection by name; it must never
# define the connection itself (that would make the repo config
# machine-specific — see SKILL.md § Repository portability).

connection_provider() {   # <connection-name>
  cfg_get_user "connections.$1.provider"
}

# The herdr agent kind a connection actually launches as. An explicit
# `kind:` on the connection always wins (needed when the provider's vendor
# name and its herdr CLI kind differ, e.g. provider openai / kind codex);
# otherwise the provider name is tried verbatim as the kind (correct for
# claude/gemini/deepseek/cursor/pi, wrong for openai unless `kind:` is set —
# that failure surfaces later as an unrecognized-kind error, never a silent
# guess at a different provider).
connection_kind() {   # <connection-name>
  local name="$1" k
  k=$(cfg_get_user "connections.$name.kind")
  if [ -n "$k" ]; then echo "$k"; return 0; fi
  connection_provider "$name"
}

connection_defined() {   # <connection-name>
  [ -n "$(connection_provider "$1")" ]
}

# ---- Complexity policy ----------------------------------------------------
# simple|normal|complex|high-risk — see SKILL.md § Task-complexity policy.
# Never inferred from the request; explicit env or repo config only.
effective_complexity() {
  local c="${FEATURE_COMPLEXITY:-}"
  [ -n "$c" ] || c=$(cfg_get_repo "complexity")
  c="${c:-normal}"
  case "$c" in
    simple|normal|complex|high-risk) echo "$c" ;;
    *) echo "warn: unknown complexity '$c' (want simple|normal|complex|high-risk) — using 'normal'" >&2
       echo normal ;;
  esac
}

# ---- Reviewer enablement --------------------------------------------------
reviewer_enabled() {
  local v="${REVIEWER_ENABLED:-}"
  [ -n "$v" ] || v=$(cfg_get_repo "reviewer.enabled")
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}
