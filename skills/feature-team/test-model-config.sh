#!/usr/bin/env bash
# Pure-logic test matrix for the configuration-scope resolver: user config,
# repo config, connections, complexity policy, reviewer enablement, feature
# persistence/escalation, and secret safety (feature-team/SKILL.md
# § Configuration scopes, § Configuration precedence). Complements
# test-provider-inheritance.sh, which covers kind detection and profile/
# model resolution WITHOUT any config file involved.
#
# Runs entirely against temp fixture files (a throwaway git repo for repo
# config, a throwaway HOME-style path for user config) — never touches this
# repository's own .feature-team/ or the real ~/.config/feature-team/.
#
# Usage: bash test-model-config.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pass=0 fail=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
user_cfg="$work/user-config.yaml"
repo_dir="$work/repo"
mkdir -p "$repo_dir"
( cd "$repo_dir" && git init -q && git commit -q --allow-empty -m init )

write_user_cfg() { cat > "$user_cfg"; }
write_repo_cfg() { mkdir -p "$repo_dir/.feature-team"; cat > "$repo_dir/.feature-team/config.yaml"; }
clear_repo_cfg() { rm -f "$repo_dir/.feature-team/config.yaml"; }

clean_env() {
  unset FEATURE_TEAM_CALLER_KIND TEAM_KIND PM_KIND SA_KIND DEV_KIND TESTER_KIND REVIEWER_KIND \
        CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED \
        CURSOR_TRACE_ID AI_AGENT \
        PM_MODEL SA_MODEL DEV_MODEL TESTER_MODEL REVIEWER_MODEL AGENT_MODEL AGENT_KIND \
        PM_MODEL_PROFILE SA_MODEL_PROFILE DEV_MODEL_PROFILE TESTER_MODEL_PROFILE REVIEWER_MODEL_PROFILE \
        TEAM_MODEL_PROFILE AGENT_MODEL_PROFILE \
        TEAM_CONNECTION PM_CONNECTION SA_CONNECTION DEV_CONNECTION TESTER_CONNECTION REVIEWER_CONNECTION \
        FEATURE_COMPLEXITY REVIEWER_ENABLED \
        CLAUDE_TOP_MODEL CLAUDE_STRONG_MODEL CLAUDE_BALANCED_MODEL CLAUDE_FAST_MODEL \
        CODEX_TOP_MODEL CODEX_STRONG_MODEL CODEX_BALANCED_MODEL CODEX_FAST_MODEL \
        OPENAI_TOP_MODEL OPENAI_STRONG_MODEL OPENAI_BALANCED_MODEL OPENAI_FAST_MODEL \
        DEEPSEEK_TOP_MODEL DEEPSEEK_STRONG_MODEL DEEPSEEK_BALANCED_MODEL DEEPSEEK_FAST_MODEL \
        GEMINI_TOP_MODEL GEMINI_STRONG_MODEL GEMINI_BALANCED_MODEL GEMINI_FAST_MODEL 2>/dev/null || true
  export FEATURE_TEAM_USER_CONFIG="$user_cfg"
}

# resolve_full <env-setup-code> <ROLE> — prints
# "kind=.. conn=.. provider=.. profile=.. model=.. source=.."
resolve_full() {
  ( cd "$repo_dir" &&
    clean_env
    eval "$1"
    # shellcheck source=agent-env.sh
    . "$here/agent-env.sh" 2>/dev/null
    resolve_role_full "$2"
    echo "kind=$RF_KIND conn=$RF_CONNECTION provider=$RF_PROVIDER profile=$RF_PROFILE model=$RF_MODEL source=$RF_SOURCE"
  )
}

check() {   # <name> <env-setup> <role> <expected>
  local name="$1" setup="$2" role="$3" expected="$4" got
  got=$(resolve_full "$setup" "$role")
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name"; pass=$((pass + 1))
  else
    echo "FAIL: $name — expected [$expected] got [$got]"; fail=$((fail + 1))
  fi
}

# ===========================================================================
# User-level default
# ===========================================================================
write_user_cfg <<'EOF'
version: 1
connections:
  com1:
    provider: openai
    kind: codex
  com2:
    provider: deepseek
defaults:
  roles:
    pm:
      connection: com1
      profile: strong
    sa:
      connection: com1
      profile: top
    dev:
      connection: com2
      profile: balanced
    tester:
      connection: com2
      profile: balanced
EOF
clear_repo_cfg

check "User default — PM resolves via com1/openai/codex" \
  ': # nothing set' PM "kind=codex conn=com1 provider=openai profile=strong model= source=user"
check "User default — DEV resolves via com2/deepseek" \
  ': # nothing set' DEV "kind=deepseek conn=com2 provider=deepseek profile=balanced model=deepseek-chat source=user"

# ===========================================================================
# Repository override — repo config wins over user config for the roles it sets
# ===========================================================================
write_repo_cfg <<'EOF'
version: 1
roles:
  dev:
    connection: com2
    profile: fast
EOF

check "Repo override — DEV profile 'fast' overrides user's 'balanced'" \
  ': # nothing set' DEV "kind=deepseek conn=com2 provider=deepseek profile=fast model=deepseek-chat source=repo"
check "Repo override — PM untouched by repo config, still falls to user default" \
  ': # nothing set' PM "kind=codex conn=com1 provider=openai profile=strong model= source=user"

# ===========================================================================
# Explicit (feature-persisted / CLI) override beats repo config
# ===========================================================================
check "Explicit override — DEV_MODEL_PROFILE=strong wins over repo's 'fast' (simulates feature persistence/escalation)" \
  'export DEV_MODEL_PROFILE=strong' DEV "kind=deepseek conn=com2 provider=deepseek profile=strong model=deepseek-reasoner source=cli"
check "Explicit override — DEV_CONNECTION beats repo config's connection" \
  'export DEV_CONNECTION=com1' DEV "kind=codex conn=com1 provider=openai profile=fast model= source=cli"

# ===========================================================================
# Escalation never mutates the repo config file on disk
# ===========================================================================
test_escalation_is_feature_scoped() {
  local before after
  before=$(cat "$repo_dir/.feature-team/config.yaml")
  ( cd "$repo_dir" && clean_env; export DEV_MODEL_PROFILE=strong
    . "$here/agent-env.sh" 2>/dev/null; resolve_role_full DEV >/dev/null )
  after=$(cat "$repo_dir/.feature-team/config.yaml")
  if [ "$before" = "$after" ]; then
    echo "PASS: Escalation via env override never rewrites repo config"; pass=$((pass + 1))
  else
    echo "FAIL: Escalation via env override mutated repo config on disk"; fail=$((fail + 1))
  fi
}
test_escalation_is_feature_scoped

# ===========================================================================
# Mixed providers via connections
# ===========================================================================
clear_repo_cfg
check "Mixed providers — PM via com1/openai" \
  ': # nothing set' PM "kind=codex conn=com1 provider=openai profile=strong model= source=user"
check "Mixed providers — DEV via com2/deepseek" \
  ': # nothing set' DEV "kind=deepseek conn=com2 provider=deepseek profile=balanced model=deepseek-chat source=user"

# ===========================================================================
# Caller inheritance when no connection/config resolves a role
# ===========================================================================
: > "$user_cfg"   # empty user config
check "Caller inheritance — no config at all, PM inherits caller kind+provider" \
  'export FEATURE_TEAM_CALLER_KIND=pi' PM "kind=pi conn= provider=pi profile=strong model= source=caller"

# ===========================================================================
# Missing connection -> MODEL_UNAVAILABLE, never a silent fallback
# ===========================================================================
write_user_cfg <<'EOF'
version: 1
connections:
  com1:
    provider: openai
EOF
write_repo_cfg <<'EOF'
version: 1
roles:
  dev:
    connection: com-does-not-exist
EOF
test_missing_connection() {
  local out status
  out=$(cd "$repo_dir" && clean_env
        . "$here/agent-env.sh" 2>/dev/null
        resolve_role_full DEV 2>&1); status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -q "MODEL_UNAVAILABLE"; then
    echo "PASS: Missing connection fails loudly with MODEL_UNAVAILABLE (no silent fallback)"
    pass=$((pass + 1))
  else
    echo "FAIL: Missing connection did not fail as expected — status=$status out=$out"
    fail=$((fail + 1))
  fi
}
test_missing_connection
clear_repo_cfg

# ===========================================================================
# Task-complexity policy — built-in default tier only (never overrides
# explicit/repo/user config; see feature-team/SKILL.md § Task-complexity policy)
# ===========================================================================
: > "$user_cfg"
clear_repo_cfg
check "Complexity simple — DEV defaults to fast" \
  'export FEATURE_TEAM_CALLER_KIND=pi; export FEATURE_COMPLEXITY=simple' DEV "kind=pi conn= provider=pi profile=fast model= source=caller"
check "Complexity high-risk — DEV defaults to strong" \
  'export FEATURE_TEAM_CALLER_KIND=pi; export FEATURE_COMPLEXITY=high-risk' DEV "kind=pi conn= provider=pi profile=strong model= source=caller"
write_user_cfg <<'EOF'
version: 1
defaults:
  roles:
    dev:
      profile: balanced
EOF
check "Complexity never overrides an explicit user-config profile" \
  'export FEATURE_TEAM_CALLER_KIND=pi; export FEATURE_COMPLEXITY=high-risk' DEV "kind=pi conn= provider=pi profile=balanced model= source=user"
: > "$user_cfg"

# ===========================================================================
# Reviewer enablement + default profile
# ===========================================================================
clear_repo_cfg
test_reviewer_disabled_by_default() {
  local out
  out=$(cd "$repo_dir" && clean_env
        . "$here/agent-env.sh" 2>/dev/null
        reviewer_enabled && echo enabled || echo disabled)
  if [ "$out" = "disabled" ]; then
    echo "PASS: Reviewer disabled by default"; pass=$((pass + 1))
  else
    echo "FAIL: Reviewer expected disabled by default, got $out"; fail=$((fail + 1))
  fi
}
test_reviewer_disabled_by_default

write_repo_cfg <<'EOF'
version: 1
reviewer:
  enabled: true
EOF
check "Reviewer enabled via repo config defaults to profile 'strong'" \
  'export FEATURE_TEAM_CALLER_KIND=pi' REVIEWER "kind=pi conn= provider=pi profile=strong model= source=caller"
clear_repo_cfg

# ===========================================================================
# Configuration source reporting (config.sh show's Source column)
# ===========================================================================
write_user_cfg <<'EOF'
version: 1
defaults:
  roles:
    pm:
      connection: com1
      profile: strong
connections:
  com1:
    provider: openai
    kind: codex
EOF
write_repo_cfg <<'EOF'
version: 1
roles:
  pm:
    connection: com1
    profile: top
EOF
check "Source reporting — repo config profile shows source=repo" \
  ': # nothing set' PM "kind=codex conn=com1 provider=openai profile=top model= source=repo"
check "Source reporting — explicit env shows source=cli" \
  'export PM_MODEL_PROFILE=fast' PM "kind=codex conn=com1 provider=openai profile=fast model= source=cli"
clear_repo_cfg
check "Source reporting — user config (no repo override) shows source=user" \
  ': # nothing set' PM "kind=codex conn=com1 provider=openai profile=strong model= source=user"
: > "$user_cfg"

# ===========================================================================
# Secret safety — config.sh show/save never print or persist secret-looking
# env vars, and repo config never contains one
# ===========================================================================
write_user_cfg <<'EOF'
version: 1
connections:
  com1:
    provider: openai
    kind: codex
defaults:
  roles:
    pm:
      connection: com1
      profile: strong
    sa:
      connection: com1
      profile: strong
    dev:
      connection: com1
      profile: strong
    tester:
      connection: com1
      profile: strong
EOF
clear_repo_cfg
test_secret_safety() {
  local secret="sk-super-secret-token-should-never-appear" out saved
  out=$(cd "$repo_dir" && clean_env
        export OPENAI_API_KEY="$secret"
        export FEATURE_TEAM_CALLER_KIND=pi
        bash "$here/config.sh" show 2>&1)
  if printf '%s' "$out" | grep -qF "$secret"; then
    echo "FAIL: Secret leaked into config.sh show output"; fail=$((fail + 1))
  else
    echo "PASS: config.sh show does not leak a secret-looking env var"; pass=$((pass + 1))
  fi
  ( cd "$repo_dir" && clean_env
    export OPENAI_API_KEY="$secret"
    export FEATURE_TEAM_CALLER_KIND=pi
    bash "$here/config.sh" save >/dev/null 2>&1 )
  saved=$(cat "$repo_dir/.feature-team/config.yaml" 2>/dev/null || true)
  if printf '%s' "$saved" | grep -qF "$secret"; then
    echo "FAIL: Secret leaked into saved .feature-team/config.yaml"; fail=$((fail + 1))
  else
    echo "PASS: config.sh save does not persist a secret-looking env var"; pass=$((pass + 1))
  fi
}
test_secret_safety
clear_repo_cfg

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
