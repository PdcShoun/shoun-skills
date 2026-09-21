#!/usr/bin/env bash
# Shared helpers for the feature-team spawn scripts.
#
# Agent-kind agnostic on purpose: nothing here knows any agent CLI's flags
# beyond a handful of confirmed defaults (see resolve_agent_args), which
# apply only when a role has no configured args. Any other kind gets
# exactly the args you pass via <ROLE>_ARGS.

here_for_registry=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config-lib.sh
. "$here_for_registry/config-lib.sh"
# shellcheck source=model-registry.sh
. "$here_for_registry/model-registry.sh"
unset here_for_registry

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
TEAM_ENV_PREFIXES="${TEAM_ENV_PREFIXES:-TEAM_ CLAUDE_ ANTHROPIC_ OPENAI_ AZURE_OPENAI_ GOOGLE_ GEMINI_ VERTEX_ XAI_ GROK_ MISTRAL_ DEEPSEEK_ OPENROUTER_ OLLAMA_ CODEX_ CURSOR_ COPILOT_ QWEN_ KIMI_ AMP_ OPENCODE_ PI_}"
TEAM_ENV_KEYS="${TEAM_ENV_KEYS:-CLAUDE_CONFIG_DIR FEATURE_TEAM_CALLER_KIND FEATURE_TEAM_USER_CONFIG PM_KIND SA_KIND DEV_KIND TESTER_KIND REVIEWER_KIND PM_ARGS SA_ARGS DEV_ARGS TESTER_ARGS REVIEWER_ARGS PM_MODEL SA_MODEL DEV_MODEL TESTER_MODEL REVIEWER_MODEL PM_MODEL_PROFILE SA_MODEL_PROFILE DEV_MODEL_PROFILE TESTER_MODEL_PROFILE REVIEWER_MODEL_PROFILE AGENT_MODEL_PROFILE PM_CONNECTION SA_CONNECTION DEV_CONNECTION TESTER_CONNECTION REVIEWER_CONNECTION TEAM_CONNECTION REVIEWER_ENABLED FEATURE_COMPLEXITY CLAUDE_CODE_USE_FOUNDRY AZURE_CONFIG_DIR TEAM_MAX_RETRIES TEAM_MAX_PARALLEL TEAM_STAGE_TIMEOUT_MS}"
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

# Args a role's agent CLI is started with. Explicit <ROLE>_ARGS always wins.
# Below that, this is a small table of PROVIDER ADAPTERS: each kind this
# skill has confirmed CLI syntax for gets its own case arm that knows how to
# pass a resolved model (never guessed — see model-registry.sh); every other
# kind either starts bare, or — only once a model was actually resolved for
# it via configuration — gets a best-effort `--model <model>` (the one flag
# most agent CLIs that accept a model happen to share). This is the ONLY
# place provider-specific CLI syntax may appear; the role/orchestration
# layer above never constructs flags itself (see feature-team/SKILL.md
# § Model selection).
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
    # claude's own default flags — model hint defaults to sonnet ONLY here,
    # never bled into another kind's model resolution.
    claude) AGENT_ARGV=(--model "${model:-sonnet}" --permission-mode auto) ;;
    # OpenAI's Codex CLI: confirmed syntax, so it earns its own adapter
    # instead of falling into the generic best-effort branch below.
    codex)
      if [ -n "$model" ]; then AGENT_ARGV=(--model "$model" --full-auto)
      else AGENT_ARGV=(--full-auto)
      fi ;;
    *)
      if [ -n "$model" ]; then
        AGENT_ARGV=(--model "$model")
      else
        echo "note: no ${role}_ARGS set for kind '$kind' — starting it bare;" \
             "set ${role}_ARGS for model/auto-approve flags" >&2
      fi ;;
  esac
}

# ---- Model selection ----------------------------------------------------
# Five independent concepts, never conflated (see feature-team/SKILL.md
# § Strict separation of concepts):
#   Role         PM / SA / DEV / TESTER / (optional) REVIEWER — a fixed
#                contract; never changes with the model
#   Connection   a named account/CLI binding on THIS machine (e.g. com1,
#                com2), defined only in user config — see config-lib.sh
#   Provider     the agent kind's own vendor (claude, openai, deepseek, ...)
#   Model Profile  top / strong / balanced / fast — a semantic, per-provider
#                SELECTION PREFERENCE, never a cross-provider equivalence
#                claim: "top" on Claude and "top" on DeepSeek are each "the
#                configured strongest model for that provider", not "the
#                same tier of model"
#   Model        a provider-specific identifier
# Role skills never see or choose a connection, provider, profile, or model
# — they only ever operate under whatever they were started with.

# Built-in default profile per role, given a complexity level (see
# effective_complexity in config-lib.sh). This is the last-resort tier —
# only consulted once no explicit env, repo config, or user config supplies
# a profile for the role. SA defaults to "top" (not just "strong") because a
# wrong architecture/design decision propagates into every downstream
# worker and is the most expensive kind of error to discover late; PM stays
# "strong" (orchestration/scope/acceptance-criteria judgment, not
# architecture); DEV/TESTER default to "balanced" because their tasks are
# constrained by SA's design + acceptance criteria + existing code; REVIEWER
# (when enabled) defaults to "strong" as an independent second opinion (see
# feature-team/SKILL.md § Recommended default model policy and
# § Task-complexity policy for the full rationale and the table this
# encodes).
role_default_profile() {   # <ROLE: PM|SA|DEV|TESTER|REVIEWER> [complexity]
  local role="$1" complexity="${2:-normal}"
  case "$complexity" in
    simple)
      case "$role" in
        PM) echo strong ;; SA) echo strong ;;
        DEV|TESTER) echo fast ;; REVIEWER) echo strong ;;
        *) echo balanced ;;
      esac ;;
    complex)
      case "$role" in
        PM) echo strong ;; SA) echo top ;;
        DEV) echo balanced ;; TESTER) echo strong ;; REVIEWER) echo strong ;;
        *) echo balanced ;;
      esac ;;
    high-risk)
      case "$role" in
        PM) echo strong ;; SA) echo top ;;
        DEV) echo strong ;; TESTER) echo strong ;; REVIEWER) echo strong ;;
        *) echo strong ;;
      esac ;;
    normal|*)
      case "$role" in
        PM) echo strong ;; SA) echo top ;;
        DEV|TESTER) echo balanced ;; REVIEWER) echo strong ;;
        *) echo balanced ;;
      esac ;;
  esac
}

# Effective semantic profile for a role. Precedence, highest first (mirrors
# feature-team/SKILL.md § Configuration precedence):
#   <ROLE>_MODEL_PROFILE          explicit per-role invocation override
#   > TEAM_MODEL_PROFILE          explicit team-wide invocation override
#   > repo config   roles.<role>.profile  (or reviewer.profile for REVIEWER)
#   > user config   defaults.roles.<role>.profile
#   > role_default_profile(role, effective_complexity())
# Sets RESOLVED_PROFILE_SOURCE to one of cli/repo/user/default — used by
# config.sh for `config show`'s Source column. Note this resolves the
# PROFILE only — resolve_role_model below layers an explicit <ROLE>_MODEL or
# a repo-remembered model on top, which wins over everything here.
RESOLVED_PROFILE_SOURCE=""
#
# NOTE on internal chaining: this function also sets RESOLVED_PROFILE (the
# same value it echoes). Any caller in THIS file that also needs
# RESOLVED_PROFILE_SOURCE must call it directly (`resolve_model_profile
# role >/dev/null`) and read both globals, NOT via `x=$(resolve_model_profile
# ...)` — command substitution forks a subshell, and a subshell's variable
# assignments never propagate back to the parent shell, so
# RESOLVED_PROFILE_SOURCE would silently read as stale/empty after a `$(...)`
# call. External callers (tests, etc.) that only want the value are unaffected
# and may keep using `$(...)`.
RESOLVED_PROFILE=""
resolve_model_profile() {   # <ROLE: PM|SA|DEV|TESTER|REVIEWER>
  local role="$1" role_var role_lc val
  role_var="${role}_MODEL_PROFILE"
  if [ -n "${!role_var:-}" ]; then
    RESOLVED_PROFILE_SOURCE=cli; RESOLVED_PROFILE="${!role_var}"; echo "$RESOLVED_PROFILE"; return 0
  fi
  if [ -n "${TEAM_MODEL_PROFILE:-}" ]; then
    RESOLVED_PROFILE_SOURCE=cli; RESOLVED_PROFILE="$TEAM_MODEL_PROFILE"; echo "$RESOLVED_PROFILE"; return 0
  fi
  role_lc=$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')
  val=$(cfg_get_repo "roles.$role_lc.profile")
  if [ -z "$val" ] && [ "$role" = REVIEWER ]; then val=$(cfg_get_repo "reviewer.profile"); fi
  if [ -n "$val" ]; then RESOLVED_PROFILE_SOURCE=repo; RESOLVED_PROFILE="$val"; echo "$val"; return 0; fi
  val=$(cfg_get_user "defaults.roles.$role_lc.profile")
  if [ -n "$val" ]; then RESOLVED_PROFILE_SOURCE=user; RESOLVED_PROFILE="$val"; echo "$val"; return 0; fi
  RESOLVED_PROFILE_SOURCE=default
  RESOLVED_PROFILE=$(role_default_profile "$role" "$(effective_complexity)")
  echo "$RESOLVED_PROFILE"
}

# Full precedence for a role's effective model:
#   explicit <ROLE>_MODEL
#   > repo config  roles.<role>.model  (a "remembered" model — see
#     config.sh save — applied only if its recorded roles.<role>.provider
#     still matches the role's actually-resolved provider; a provider
#     change never silently reuses a stale pinned model id)
#   > provider_profile_model(kind, resolve_model_profile(role))
#   > "" (provider's own CLI default — see resolve_agent_args; never
#     another provider's or another profile's model)
# Sets RESOLVED_MODEL (same value echoed) and RESOLVED_MODEL_SOURCE to
# cli/repo/<profile source>. See the subshell-chaining note above
# resolve_model_profile — the same rule applies here.
RESOLVED_MODEL="" RESOLVED_MODEL_SOURCE=""
resolve_role_model() {   # <ROLE> <kind> <explicit-model> [resolved-provider]
  local role="$1" kind="$2" explicit="$3" resolved_provider="${4:-}"
  local role_lc repo_model repo_provider
  if [ -n "$explicit" ]; then
    RESOLVED_MODEL_SOURCE=cli; RESOLVED_MODEL="$explicit"; echo "$RESOLVED_MODEL"; return 0
  fi
  role_lc=$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')
  repo_model=$(cfg_get_repo "roles.$role_lc.model")
  repo_provider=$(cfg_get_repo "roles.$role_lc.provider")
  if [ -n "$repo_model" ]; then
    if [ -z "$repo_provider" ] || [ -z "$resolved_provider" ] || [ "$repo_provider" = "$resolved_provider" ]; then
      RESOLVED_MODEL_SOURCE=repo; RESOLVED_MODEL="$repo_model"; echo "$RESOLVED_MODEL"; return 0
    fi
    echo "warn: repo config remembers a $role model for provider '$repo_provider'," \
         "but the resolved provider is now '$resolved_provider' — ignoring the" \
         "remembered model (provider changed; never silently reused across a" \
         "provider switch)" >&2
  fi
  resolve_model_profile "$role" >/dev/null
  RESOLVED_MODEL_SOURCE="$RESOLVED_PROFILE_SOURCE"
  RESOLVED_MODEL=$(provider_profile_model "$kind" "$RESOLVED_PROFILE")
  echo "$RESOLVED_MODEL"
}

# ---- Caller-kind detection ----------------------------------------------
# The team's default provider is whichever agent/CLI invoked feature-team —
# never a hardcoded kind. Resolution order, cheapest/most-authoritative first:
#   1. $FEATURE_TEAM_CALLER_KIND — set this if the calling agent (or its
#      harness) already knows its own kind, which it always does. This is the
#      ONLY mechanism guaranteed to work for a provider this script has no
#      built-in signal for (e.g. a brand new kind herdr just added support
#      for). Any agent can `export FEATURE_TEAM_CALLER_KIND=<its own kind>`
#      before invoking spawn-team.sh/spawn-agent.sh/spawn-workstream.sh.
#   2. Well-known runtime signals for providers we can detect without being
#      told anything — best-effort, extend the case below as new signals are
#      confirmed. Never assume "if nothing else matched, it must be claude".
#   3. Undetected: return 1 (empty stdout). Every caller of this function
#      MUST fail_no_provider rather than substitute a default kind — see
#      resolve_team_kind and the three spawn-*.sh scripts.
detect_caller_kind() {
  if [ -n "${FEATURE_TEAM_CALLER_KIND:-}" ]; then
    echo "$FEATURE_TEAM_CALLER_KIND"; return 0
  fi
  # Claude Code CLI sets these on its own process (verified: CLAUDECODE=1 is
  # present for every `claude` invocation, including subshells it runs).
  if [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
    echo claude; return 0
  fi
  # Codex CLI's sandbox markers.
  if [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ]; then
    echo codex; return 0
  fi
  # Cursor's agent/background-agent env.
  if [ -n "${CURSOR_TRACE_ID:-}" ]; then
    echo cursor; return 0
  fi
  # Generic "which AI CLI is driving this shell" convention some terminal
  # integrations set (observed: Warp sets AI_AGENT to a slug like
  # "claude-code_2-1-267_agent"). Parse the leading provider slug rather than
  # trusting the value verbatim, since the exact suffix format isn't ours to
  # rely on.
  if [ -n "${AI_AGENT:-}" ]; then
    case "$AI_AGENT" in
      claude*) echo claude; return 0 ;;
      codex*) echo codex; return 0 ;;
      gemini*) echo gemini; return 0 ;;
      cursor*) echo cursor; return 0 ;;
      pi|pi-*|pi_*) echo pi; return 0 ;;
    esac
  fi
  return 1
}

# Effective kind for the whole team: explicit $TEAM_KIND wins, else whatever
# detect_caller_kind resolves. Prints nothing and returns 1 if neither
# resolves — the caller must fail_no_provider, never pick a default itself.
resolve_team_kind() {
  if [ -n "${TEAM_KIND:-}" ]; then echo "$TEAM_KIND"; return 0; fi
  detect_caller_kind
}

# The one sanctioned way to give up when no provider can be determined. Never
# call `validate_kind claude` (or any other kind) as a substitute for this.
fail_no_provider() {   # <which-var-the-user-should-set> e.g. TEAM_KIND, AGENT_KIND
  echo "Unable to determine calling agent provider." >&2
  echo "Set ${1:-TEAM_KIND} explicitly, or export FEATURE_TEAM_CALLER_KIND=<kind>" \
       "(pi, claude, codex, gemini, cursor, ...) before invoking this script." >&2
  exit 1
}

# A referenced connection name that resolves to nothing is never treated as
# "no opinion" the way a missing model does — a NAMED connection was
# expected to exist, so its absence is a configuration error, not silence.
# Never falls back to another connection/provider (feature-team/SKILL.md
# § Detect configuration drift).
fail_model_unavailable() {   # <role> <connection-name> <where-it-was-configured>
  echo "MODEL_UNAVAILABLE" >&2
  echo "Role $1's configuration ($3) references connection '$2', which is not" \
       "defined in the user config ($(user_config_path))." >&2
  echo "Define it under connections: in that file, or override ${1}_CONNECTION or" \
       "${1}_KIND explicitly for this run. Never silently substituting another" \
       "connection/provider." >&2
  exit 1
}

# ---- Role kind + connection + provider resolution ------------------------
# Full precedence for a named role's (PM/SA/DEV/TESTER/REVIEWER) effective
# kind, mirroring feature-team/SKILL.md § Configuration precedence:
#   <ROLE>_KIND                          explicit per-role invocation override
#   > TEAM_KIND                          explicit team-wide invocation override
#   > <ROLE>_CONNECTION  -> connection's kind   explicit per-role connection
#   > TEAM_CONNECTION    -> connection's kind   explicit team-wide connection
#   > repo config   roles.<role>.connection -> connection's kind
#   > user config   defaults.roles.<role>.connection -> connection's kind
#   > caller kind (detect_caller_kind)
#   > fail_no_provider
# A connection NAME that doesn't resolve to a defined connection is always a
# hard failure (fail_model_unavailable) — never silently skipped in favor of
# the next tier, because that would be exactly the kind of silent
# provider/connection switch this skill refuses to do.
#
# Sets globals: RESOLVED_KIND RESOLVED_PROVIDER RESOLVED_CONNECTION
# RESOLVED_KIND_SOURCE (cli/repo/user/caller).
RESOLVED_KIND="" RESOLVED_PROVIDER="" RESOLVED_CONNECTION="" RESOLVED_KIND_SOURCE=""
resolve_role_kind() {   # <ROLE: PM|SA|DEV|TESTER|REVIEWER>
  local role="$1" role_kind_var="${1}_KIND" role_conn_var="${1}_CONNECTION"
  local role_lc kind="" conn="" source=""

  role_lc=$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')

  if [ -n "${!role_kind_var:-}" ]; then
    kind="${!role_kind_var}"; source=cli
  elif [ -n "${TEAM_KIND:-}" ]; then
    kind="$TEAM_KIND"; source=cli
  elif [ -n "${!role_conn_var:-}" ]; then
    conn="${!role_conn_var}"
    connection_defined "$conn" || fail_model_unavailable "$role" "$conn" "\$${role_conn_var}"
    kind=$(connection_kind "$conn"); source=cli
  elif [ -n "${TEAM_CONNECTION:-}" ]; then
    conn="$TEAM_CONNECTION"
    connection_defined "$conn" || fail_model_unavailable "$role" "$conn" "\$TEAM_CONNECTION"
    kind=$(connection_kind "$conn"); source=cli
  elif conn=$(cfg_get_repo "roles.$role_lc.connection") && [ -n "$conn" ]; then
    connection_defined "$conn" || fail_model_unavailable "$role" "$conn" "repository config roles.$role_lc.connection"
    kind=$(connection_kind "$conn"); source=repo
  elif conn=$(cfg_get_user "defaults.roles.$role_lc.connection") && [ -n "$conn" ]; then
    connection_defined "$conn" || fail_model_unavailable "$role" "$conn" "user config defaults.roles.$role_lc.connection"
    kind=$(connection_kind "$conn"); source=user
  else
    conn=""; kind=$(detect_caller_kind || true); source=caller
  fi

  RESOLVED_KIND="$kind"
  RESOLVED_CONNECTION="$conn"
  RESOLVED_KIND_SOURCE="$source"
  if [ -n "$conn" ]; then
    RESOLVED_PROVIDER=$(connection_provider "$conn")
  elif [ -n "$kind" ]; then
    RESOLVED_PROVIDER=$(kind_vendor_family "$kind")
  else
    RESOLVED_PROVIDER=""
  fi
}

# One tag summarizing where a role's effective configuration actually came
# from, for `config.sh show`'s Source column (feature-team/SKILL.md
# § Configuration display) — the higher-precedence of the kind/connection
# source and the profile source, in the same order as § Configuration
# precedence.
rf_combined_source() {   # <kind-source> <profile-source>
  local a="$1" b="$2" s
  for s in cli repo user caller default; do
    [ "$a" = "$s" ] || [ "$b" = "$s" ] && { echo "$s"; return 0; }
  done
  echo default
}

# Resolves everything for one named role in one call: kind, connection,
# provider, profile, model, and a combined provenance tag. Used by both
# spawn-team.sh (to actually start the agent) and config.sh (to report the
# effective configuration without starting anything).
# Sets: RF_KIND RF_CONNECTION RF_PROVIDER RF_PROFILE RF_MODEL RF_SOURCE
resolve_role_full() {   # <ROLE: PM|SA|DEV|TESTER|REVIEWER>
  local role="$1" explicit_model_var="${1}_MODEL"
  local kind_source profile_source model_source
  # Called directly (never via `$(...)`) so the RESOLVED_*_SOURCE globals
  # each sets land in THIS shell, not a discarded subshell — see the note
  # above resolve_model_profile.
  resolve_role_kind "$role"
  RF_KIND="$RESOLVED_KIND"; RF_CONNECTION="$RESOLVED_CONNECTION"
  RF_PROVIDER="$RESOLVED_PROVIDER"; kind_source="$RESOLVED_KIND_SOURCE"
  resolve_model_profile "$role" >/dev/null
  RF_PROFILE="$RESOLVED_PROFILE"; profile_source="$RESOLVED_PROFILE_SOURCE"
  resolve_role_model "$role" "$RF_KIND" "${!explicit_model_var:-}" "$RF_PROVIDER" >/dev/null
  RF_MODEL="$RESOLVED_MODEL"; model_source="$RESOLVED_MODEL_SOURCE"
  RF_SOURCE=$(rf_combined_source "$kind_source" "$profile_source")
  if [ "$model_source" = cli ]; then
    RF_SOURCE=cli
  elif [ "$model_source" = repo ] && [ "$RF_SOURCE" != cli ]; then
    RF_SOURCE=repo
  fi
  return 0
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

ROLE_SKILLS="pm sa dev tester reviewer handoff git security"

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
