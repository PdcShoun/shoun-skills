#!/usr/bin/env bash
# Shared helpers for the feature-team spawn scripts.
#
# Agent-kind agnostic on purpose: nothing here knows any agent CLI's flags
# except the claude defaults, which apply only when a role has no configured
# args. Any other kind gets exactly the args you pass via <ROLE>_ARGS.

require_deps() {
  command -v jq >/dev/null || { echo "jq required"; exit 1; }
  command -v herdr >/dev/null || { echo "herdr required"; exit 1; }
  test "${HERDR_ENV:-}" = 1 || { echo "not inside Herdr (HERDR_ENV!=1)"; exit 1; }
}

# herdr prints "  kinds: pi|claude|codex|..." — fail fast on a typo'd kind
# instead of after four panes have been created.
validate_kind() {
  local kind="$1" kinds
  # bare `herdr agent` is a usage message and exits nonzero — that is expected
  kinds=$(herdr agent 2>&1 | sed -n 's/^ *kinds: *//p' | head -1) || true
  [ -n "$kinds" ] || return 0   # output changed shape; let herdr reject it
  case "|$kinds|" in
    *"|$kind|"*) return 0 ;;
    *) echo "unknown agent kind '$kind' (herdr kinds: $kinds)"; exit 1 ;;
  esac
}

# Provider/config env forwarded to the new panes so the team runs against the
# same account and settings as the caller. Discovery is by prefix over what is
# actually set — no per-agent-kind knowledge — minus per-session vars that
# point back at the launching agent.
TEAM_ENV_PREFIXES="${TEAM_ENV_PREFIXES:-TEAM_ ANTHROPIC_ OPENAI_ AZURE_OPENAI_ GOOGLE_ GEMINI_ VERTEX_ XAI_ GROK_ MISTRAL_ DEEPSEEK_ OPENROUTER_ OLLAMA_ CODEX_ CURSOR_ COPILOT_ QWEN_ KIMI_ AMP_ OPENCODE_}"
TEAM_ENV_KEYS="${TEAM_ENV_KEYS:-CLAUDE_CONFIG_DIR PM_KIND SA_KIND DEV_KIND TESTER_KIND PM_ARGS SA_ARGS DEV_ARGS TESTER_ARGS PM_MODEL SA_MODEL DEV_MODEL TESTER_MODEL CLAUDE_CODE_USE_FOUNDRY AZURE_CONFIG_DIR TEAM_MAX_RETRIES TEAM_MAX_PARALLEL TEAM_STAGE_TIMEOUT_MS}"
TEAM_ENV_DENY="${TEAM_ENV_DENY:-CLAUDE_CODE_ HERDR_}"

# Fills the TEAM_ENV array with --env K=V pairs for `herdr` calls.
# TEAM_ENV_KEYS is an explicit allowlist and wins over TEAM_ENV_DENY — the deny
# list exists to stop *prefix*-matched vars (e.g. all of CLAUDE_CODE_) from
# leaking into child panes, not to block a var someone named on purpose.
TEAM_ENV=()
build_team_env() {
  TEAM_ENV=()
  local k v pfx want keep explicit
  while IFS= read -r k; do
    keep=0 explicit=0
    for pfx in $TEAM_ENV_PREFIXES; do case "$k" in "$pfx"*) keep=1 ;; esac; done
    for want in $TEAM_ENV_KEYS; do [ "$k" = "$want" ] && keep=1 && explicit=1; done
    [ "$keep" = 1 ] || continue
    if [ "$explicit" = 0 ]; then
      for pfx in $TEAM_ENV_DENY; do case "$k" in "$pfx"*) keep=0 ;; esac; done
    fi
    [ "$keep" = 1 ] || continue
    v=$(printenv "$k") && [ -n "$v" ] || continue
    TEAM_ENV+=(--env "$k=$v")
  done < <(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | sort -u)
}

# Args a role's agent CLI is started with. Explicit <ROLE>_ARGS wins; the only
# built-in default is claude's, the kind this skill was first written against.
# Fills the AGENT_ARGV array.
AGENT_ARGV=()
resolve_agent_args() {   # <role-label> <kind> <configured-args> <model-hint>
  local role="$1" kind="$2" args="$3" model="$4"
  AGENT_ARGV=()
  if [ -n "$args" ]; then
    read -ra AGENT_ARGV <<<"$args"   # whitespace-separated, no quoting
    return 0
  fi
  case "$kind" in
    claude) AGENT_ARGV=(--model "$model" --permission-mode auto) ;;
    *) echo "note: no ${role}_ARGS set for kind '$kind' — starting it bare;" \
            "set ${role}_ARGS for model/auto-approve flags" >&2 ;;
  esac
}

# Start an agent, passing resolved args after `--` only when there are some.
start_agent() {   # <name> <pane> <kind> [args...]
  local name="$1" pane="$2" kind="$3"; shift 3
  if [ "$#" -gt 0 ]; then
    herdr agent start "$name" --kind "$kind" --pane "$pane" -- "$@"
  else
    herdr agent start "$name" --kind "$kind" --pane "$pane"
  fi
}

# The default branch of the repo at $PWD (or the nearest sensible fallback).
# Used so nothing ever assumes "main" — worktree bases and PR targets must
# track whatever the remote (or local checkout) actually considers default.
detect_default_branch() {
  local ref
  # each candidate must be checked for a non-empty result itself — piping
  # through sed would mask a failed/empty git command with sed's own exit 0
  ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) \
    && [ -n "$ref" ] && { echo "${ref#origin/}"; return; }
  ref=$(git remote show origin 2>/dev/null | sed -n 's/^ *HEAD branch: *//p') \
    && [ -n "$ref" ] && { echo "$ref"; return; }
  ref=$(git branch --show-current 2>/dev/null) \
    && [ -n "$ref" ] && { echo "$ref"; return; }
  echo main
}

# Renders TEAM_ENV (pairs of `--env` and `K=V`, set by build_team_env) as a
# single `export K=V; ...` command string. Needed because `herdr worktree
# create/open` has no `--env` flag (unlike `pane split` / `workspace create`):
# the workaround is to run this in the fresh worktree pane's shell *before*
# `agent start`, so the agent process inherits the vars via normal shell
# export semantics.
team_env_export_cmd() {
  local out="" i kv k v q
  for ((i = 0; i < ${#TEAM_ENV[@]}; i += 2)); do
    kv="${TEAM_ENV[i + 1]}"
    k="${kv%%=*}"; v="${kv#*=}"
    printf -v q '%q' "$v"
    out+="export $k=$q; "
  done
  printf '%s' "$out"
}

# ---- Feature-doc helpers -----------------------------------------------
# The tracking doc (docs/features/<slug>.md) carries a fenced ```state block
# (see templates/feature-doc.md) with flat `key: value` lines — the
# machine-readable half of the doc. These helpers are the ONLY sanctioned way
# to read/write it, so every PM run (and every resume) produces the same
# shape instead of relying on an LLM to hand-edit markdown consistently.

# Print the current value of `key` from the ```state block, or nothing.
doc_get_field() {   # <doc-file> <key>
  awk -v key="$2" '
    /^```state[ \t]*$/ { in_block=1; next }
    in_block && /^```[ \t]*$/ { in_block=0 }
    in_block && $0 ~ "^" key ":[ \t]*" {
      sub("^" key ":[ \t]*", ""); print; exit
    }
  ' "$1"
}

# Idempotently set `key: value` inside the ```state block: replaces the line
# if present, appends it just before the closing fence otherwise. No-op (with
# a warning) if the doc has no ```state block at all.
doc_set_field() {   # <doc-file> <key> <value>
  local file="$1" key="$2" value="$3" tmp
  grep -q '^```state[ \t]*$' "$file" 2>/dev/null || {
    echo "warn: $file has no \`\`\`state block — cannot set $key" >&2; return 1;
  }
  tmp=$(mktemp "${file}.XXXXXX")
  awk -v key="$key" -v val="$value" '
    /^```state[ \t]*$/ { in_block=1; print; next }
    in_block && /^```[ \t]*$/ {
      if (!done) { print key ": " val; done=1 }
      in_block=0; print; next
    }
    in_block && $0 ~ "^" key ":" { print key ": " val; done=1; next }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Append one line to the end of "## Stage log" (before the next `## ` heading,
# or at EOF if it's the last section). Keeps every checkpoint in one place in
# a fixed format instead of free-form prose scattered through the doc.
append_stage_log() {   # <doc-file> <line-text, no leading "- ">
  local file="$1" text="$2" tmp
  grep -q '^## Stage log[ \t]*$' "$file" 2>/dev/null || {
    echo "warn: $file has no '## Stage log' section — cannot append" >&2; return 1;
  }
  tmp=$(mktemp "${file}.XXXXXX")
  awk -v text="$text" '
    /^## / {
      if (in_sec && !inserted) { print "- " text; inserted=1 }
      in_sec = ($0 == "## Stage log") ? 1 : 0
      print; next
    }
    { print }
    END { if (in_sec && !inserted) print "- " text }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}
