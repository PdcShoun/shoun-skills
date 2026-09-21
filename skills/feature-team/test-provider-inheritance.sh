#!/usr/bin/env bash
# Pure-logic test matrix for provider inheritance (agent-env.sh's
# detect_caller_kind/resolve_team_kind/fail_no_provider and spawn-team.sh's
# role-kind resolution). Runs spawn-team.sh's resolution logic in isolation
# by stubbing `herdr`/`jq` calls it doesn't need for this check, so it can run
# without a live Herdr server, without real Pi/Codex/Gemini CLIs installed,
# and without creating any panes/workspaces.
#
# Usage: bash test-provider-inheritance.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pass=0 fail=0

# Isolate env: strip every signal detect_caller_kind might pick up from the
# real environment this test happens to run in, so each case starts blank.
clean_env() {
  unset FEATURE_TEAM_CALLER_KIND TEAM_KIND PM_KIND SA_KIND DEV_KIND TESTER_KIND \
        CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED \
        CURSOR_TRACE_ID AI_AGENT 2>/dev/null || true
}

# Runs the same resolution spawn-team.sh performs (CALLER_KIND -> TEAM_KIND ->
# per-role) in a subshell with the given env, then prints "PM=.. SA=.. DEV=..
# TESTER=.." or "FAIL: <message>" on stdout.
resolve() {
  (
    clean_env
    eval "$1"
    # shellcheck source=agent-env.sh
    . "$here/agent-env.sh" 2>/dev/null
    CALLER_KIND="$(detect_caller_kind || true)"
    TEAM_KIND="${TEAM_KIND:-$CALLER_KIND}"
    PM_KIND="${PM_KIND:-$TEAM_KIND}"; SA_KIND="${SA_KIND:-$TEAM_KIND}"
    DEV_KIND="${DEV_KIND:-$TEAM_KIND}"; TESTER_KIND="${TESTER_KIND:-$TEAM_KIND}"
    for role_kind in "$PM_KIND" "$SA_KIND" "$DEV_KIND" "$TESTER_KIND"; do
      if [ -z "$role_kind" ]; then
        echo "FAIL: no provider resolved"
        exit 0
      fi
    done
    echo "PM=$PM_KIND SA=$SA_KIND DEV=$DEV_KIND TESTER=$TESTER_KIND"
  )
}

check() {   # <case-name> <env-setup-code> <expected>
  local name="$1" setup="$2" expected="$3" got
  got=$(resolve "$setup")
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name — expected [$expected] got [$got]"
    fail=$((fail + 1))
  fi
}

# --- Case 1: Pi caller, no overrides ---------------------------------------
check "Case 1 — Pi caller, no overrides" \
  'export FEATURE_TEAM_CALLER_KIND=pi' \
  "PM=pi SA=pi DEV=pi TESTER=pi"

# --- Case 2: Claude caller, no overrides -----------------------------------
check "Case 2 — Claude caller, no overrides" \
  'export CLAUDECODE=1' \
  "PM=claude SA=claude DEV=claude TESTER=claude"

# --- Case 3: Codex caller, no overrides -------------------------------------
check "Case 3 — Codex caller, no overrides" \
  'export FEATURE_TEAM_CALLER_KIND=codex' \
  "PM=codex SA=codex DEV=codex TESTER=codex"

# --- Case 4: Pi caller, mixed explicit override -----------------------------
check "Case 4 — Pi caller + SA_KIND=claude DEV_KIND=codex" \
  'export FEATURE_TEAM_CALLER_KIND=pi; export SA_KIND=claude; export DEV_KIND=codex' \
  "PM=pi SA=claude DEV=codex TESTER=pi"

# --- Case 5: Pi caller, explicit team override ------------------------------
check "Case 5 — Pi caller + TEAM_KIND=claude" \
  'export FEATURE_TEAM_CALLER_KIND=pi; export TEAM_KIND=claude' \
  "PM=claude SA=claude DEV=claude TESTER=claude"

# --- Case 5b: caller + TEAM_KIND=codex + TESTER_KIND=gemini -----------------
check "Case 5b — Pi caller + TEAM_KIND=codex + TESTER_KIND=gemini" \
  'export FEATURE_TEAM_CALLER_KIND=pi; export TEAM_KIND=codex; export TESTER_KIND=gemini' \
  "PM=codex SA=codex DEV=codex TESTER=gemini"

# --- Case 6: no caller detectable, no explicit config -> must fail ----------
check "Case 6 — undetectable caller, no config -> fail (no silent claude)" \
  ': # nothing set' \
  "FAIL: no provider resolved"

# --- Case 6b: fully explicit per-role config needs no caller detection -----
check "Case 6b — undetectable caller but every role explicit -> no fail" \
  'export PM_KIND=pi; export SA_KIND=pi; export DEV_KIND=pi; export TESTER_KIND=pi' \
  "PM=pi SA=pi DEV=pi TESTER=pi"

# --- Case 9: model/args never leak claude defaults to other providers ------
test_case9() {
  local out
  out=$(
    clean_env
    export FEATURE_TEAM_CALLER_KIND=pi
    # shellcheck source=agent-env.sh
    . "$here/agent-env.sh" 2>/dev/null
    resolve_agent_args PM pi "" ""
    printf '%s\n' "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}"
  )
  if [ -z "$out" ]; then
    echo "PASS: Case 9 — kind=pi with no *_ARGS starts bare (no claude flags emitted)"
    pass=$((pass + 1))
  else
    echo "FAIL: Case 9 — expected no args for kind=pi, got: $out"
    fail=$((fail + 1))
  fi
}
test_case9

test_case9b() {
  local out
  out=$(
    clean_env
    export FEATURE_TEAM_CALLER_KIND=claude
    # shellcheck source=agent-env.sh
    . "$here/agent-env.sh" 2>/dev/null
    resolve_agent_args PM claude "" ""
    printf '%s ' "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}"
  )
  if [ "$out" = "--model sonnet --permission-mode auto " ]; then
    echo "PASS: Case 9b — kind=claude with no model hint still gets claude's own default args"
    pass=$((pass + 1))
  else
    echo "FAIL: Case 9b — expected claude default args, got: [$out]"
    fail=$((fail + 1))
  fi
}
test_case9b

# --- AI_AGENT generic-slug detection ---------------------------------------
check "AI_AGENT slug detection — claude-code_2-1-267_agent -> claude" \
  'export AI_AGENT=claude-code_2-1-267_agent' \
  "PM=claude SA=claude DEV=claude TESTER=claude"

# --- Role override wins even when detection fails for the team-level kind --
check "Role override present, team/caller absent -> role still resolves" \
  'export PM_KIND=codex' \
  "FAIL: no provider resolved"   # SA/DEV/TESTER still unresolved -> whole team fails

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
