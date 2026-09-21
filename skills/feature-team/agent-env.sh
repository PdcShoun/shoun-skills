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

# ---- Role-skill resolution ---------------------------------------------
# The role contracts (feature-pm/sa/dev/tester + the shared feature-handoff/
# git/security) are separate skills. Agents load them by READING THE FILE at
# an absolute path — the one mechanism every agent kind has — so nothing here
# depends on a provider's own skill loader. Resolution is a script, not a
# guess in a prompt, because an agent that silently fails to find its contract
# looks exactly like one that read it and ignored it.

FEATURE_TEAM_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Absolute path to a sibling/installed role skill's SKILL.md, or empty.
role_skill_path() {   # <skill-name>
  local name="$1" c d
  for c in "$FEATURE_TEAM_DIR/../$name/SKILL.md" \
           "$PWD/.claude/skills/$name/SKILL.md" \
           "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/$name/SKILL.md"; do
    if [ -f "$c" ]; then
      d=$(cd -- "$(dirname -- "$c")" && pwd -P) || return 1
      echo "$d/SKILL.md"
      return 0
    fi
  done
  return 1
}

ROLE_SKILLS="pm sa dev tester handoff git security"

# Emit the resolved paths as a JSON object; warn once per missing skill.
role_skills_json() {
  local r p out=() missing=()
  for r in $ROLE_SKILLS; do
    if p=$(role_skill_path "feature-$r"); then out+=("$r" "$p"); else missing+=("feature-$r"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "warn: role skill(s) not found: ${missing[*]} — agents will fall back to" \
         "the condensed role summary in feature-team/SKILL.md. Install them" \
         "alongside feature-team (they live next to it in the same skills repo)." >&2
  fi
  [ "${#out[@]}" -gt 0 ] || { echo '{}'; return 0; }
  printf '%s\n' "${out[@]}" | jq -R . \
    | jq -sc '[ . as $a | range(0; length; 2) | {key: $a[.], value: $a[.+1]} ] | from_entries'
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

# Append one structured Progress Log stamp — see templates/feature-doc.md for
# the exact shape (a "[<ts>] STAGE → STATUS" header, then Summary/Evidence/
# PM verification/Result/Next). Inserted before the next `## ` heading, or at
# EOF if the log is the doc's last section. Works against either heading name
# so a pre-existing doc that still says "## Stage log" (the old one-line-per-
# checkpoint format) keeps accumulating entries in the new format without a
# rename/migration (see feature-pm § Backward Compatibility).
#
# Idempotent: a (stage, status, summary, result) tuple identical to one
# already in the doc is not appended again — a hidden `<!-- progress-key -->`
# marker after each stamp is how a retry, replay, or resume is told apart
# from a genuinely new checkpoint (feature-pm § Idempotency). Returns 1 (and
# updates nothing) when it skips a duplicate, so callers can tell the two
# cases apart.
append_progress_entry() {   # <doc-file> <STAGE> <STATUS> <summary> <evidence "- x\n- y"> <pmverify "- x\n- y"> <result> <next>
  local file="$1" stage="$2" status="$3" summary="$4" evidence="$5" pmverify="$6" result="$7" next="$8"
  local heading ts fp block tmp
  if grep -q '^## Progress Log[ \t]*$' "$file" 2>/dev/null; then
    heading="## Progress Log"
  elif grep -q '^## Stage log[ \t]*$' "$file" 2>/dev/null; then
    heading="## Stage log"
  else
    echo "warn: $file has no '## Progress Log' or '## Stage log' section — cannot append" >&2
    return 1
  fi

  fp=$(printf '%s\x1e%s\x1e%s\x1e%s' "$stage" "$status" "$summary" "$result" | cksum | tr -d ' \t')
  if grep -qF "<!-- progress-key: $fp -->" "$file" 2>/dev/null; then
    echo "duplicate checkpoint ($stage -> $status, same summary/result already logged) — skipping entry" >&2
    return 1
  fi

  ts=$(date -u +"%Y-%m-%d %H:%M UTC")
  block="[$ts] $stage → $status"$'\n\n'"Summary:"$'\n'"$summary"
  [ -n "$evidence" ] && block+=$'\n\n'"Evidence:"$'\n'"$evidence"
  [ -n "$pmverify" ] && block+=$'\n\n'"PM verification:"$'\n'"$pmverify"
  block+=$'\n\n'"Result:"$'\n'"$result"
  [ -n "$next" ] && block+=$'\n\n'"Next:"$'\n'"$next"
  block+=$'\n'"<!-- progress-key: $fp -->"

  # Find the line to insert before: the next "## " heading after $heading, or
  # one past EOF if $heading's section runs to the end of the file. Done as a
  # line-number lookup (not a single awk pass emitting the block) because the
  # block is a multi-line string, and BSD/mawk `awk -v` (unlike gawk) rejects
  # an embedded newline in a -v-assigned value.
  local insert_at
  insert_at=$(awk -v heading="$heading" '
    $0 == heading { in_sec=1; next }
    in_sec && /^## / { print NR; f=1; exit }
    { last=NR }
    END { if (!f) print last + 1 }
  ' "$file")

  tmp=$(mktemp "${file}.XXXXXX")
  head -n "$((insert_at - 1))" "$file" > "$tmp"
  {
    printf '\n%s\n\n' "$block"
  } >> "$tmp"
  tail -n "+$insert_at" "$file" >> "$tmp"
  mv "$tmp" "$file"
}
