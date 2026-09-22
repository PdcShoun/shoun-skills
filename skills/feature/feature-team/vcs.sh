#!/usr/bin/env bash
# Git-forge abstraction: GitHub (gh), GitLab (glab), Gitea (tea) — so
# feature-team's issue/PR tracking works on whichever forge `origin` points
# at, instead of assuming GitHub. Callable directly as a CLI (see dispatch at
# the bottom) or sourced for its vcs_* functions (checkpoint.sh does this).
#
# Provider is detected from `origin`'s hostname; override for a self-hosted
# instance on an unrecognized domain with FEATURE_GIT_PROVIDER=github|gitlab|gitea.
#
# Usage (CLI mode):
#   vcs.sh detect
#   vcs.sh issue-create  <title> <body>          # prints the new issue's number
#   vcs.sh issue-comment <number> <body>
#   vcs.sh issue-search  <query>                  # prints first match's number, if any
#   vcs.sh pr-list-head  <branch>                  # prints first open PR/MR number, if any
#   vcs.sh pr-create     <base> <head> <title> <body>   # prints the new PR/MR's URL
set -euo pipefail

VCS_PROVIDER=""
VCS_CLI=""

vcs_detect() {
  [ -n "$VCS_PROVIDER" ] && return 0   # memoize within one process
  if [ -n "${FEATURE_GIT_PROVIDER:-}" ]; then
    VCS_PROVIDER="$FEATURE_GIT_PROVIDER"
  else
    local url host
    url=$(git remote get-url origin 2>/dev/null) || url=""
    host=$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://##; s#^[^@/]*@##; s#[:/].*$##')
    case "$host" in
      *github*)           VCS_PROVIDER=github ;;
      *gitlab*)           VCS_PROVIDER=gitlab ;;
      *gitea*|*codeberg*) VCS_PROVIDER=gitea ;;
      "")                 VCS_PROVIDER=none ;;
      *)
        # unrecognized host (self-hosted/custom domain) — ask whichever CLI
        # is installed whether it already knows this host; first hit wins.
        if command -v gh >/dev/null 2>&1 && gh auth status --hostname "$host" >/dev/null 2>&1; then
          VCS_PROVIDER=github
        elif command -v glab >/dev/null 2>&1 && glab auth status --hostname "$host" >/dev/null 2>&1; then
          VCS_PROVIDER=gitlab
        elif command -v tea >/dev/null 2>&1 && tea login list 2>/dev/null | grep -qF "$host"; then
          VCS_PROVIDER=gitea
        else
          VCS_PROVIDER=unknown
        fi
        ;;
    esac
  fi
  case "$VCS_PROVIDER" in
    github) VCS_CLI=gh ;;
    gitlab) VCS_CLI=glab ;;
    gitea)  VCS_CLI=tea ;;
    *)      VCS_CLI="" ;;
  esac
}

vcs_available() {
  vcs_detect
  [ -n "$VCS_CLI" ] && command -v "$VCS_CLI" >/dev/null 2>&1
}

# Every supported CLI prints the new issue/PR's URL as (or on) its create
# command's last line — pull the trailing id off it rather than parsing
# per-provider output shapes.
_vcs_last_number() {
  printf '%s\n' "$1" | grep -Eo '[0-9]+' | tail -1
}

vcs_issue_create() {   # <title> <body>
  vcs_detect
  local title="$1" body="$2" out
  case "$VCS_PROVIDER" in
    github) out=$(gh issue create --title "$title" --body "$body") ;;
    gitlab) out=$(glab issue create --title "$title" --description "$body") ;;
    gitea)  out=$(tea issues create --title "$title" --description "$body") ;;
    *) echo "warn: no supported forge CLI detected/authenticated — skipping issue creation" >&2; return 1 ;;
  esac
  _vcs_last_number "$out"
}

vcs_issue_comment() {   # <number> <body>
  vcs_detect
  local number="$1" body="$2"
  case "$VCS_PROVIDER" in
    github) gh issue comment "$number" --body "$body" ;;
    gitlab) glab issue note "$number" --message "$body" ;;
    gitea)  tea comments add "$number" --description "$body" ;;
    *) return 1 ;;
  esac
}

vcs_issue_search() {   # <query> — prints the first matching issue's number, if any
  vcs_detect
  local query="$1" num=""
  case "$VCS_PROVIDER" in
    github) num=$(gh issue list --search "$query" --json number --jq '.[0].number' 2>/dev/null) || true ;;
    gitlab) num=$(glab issue list --search "$query" -F json 2>/dev/null | jq -r '.[0].iid // empty') || true ;;
    gitea)  num=$(tea issues list --keyword "$query" --output json 2>/dev/null | jq -r '.[0].index // empty') || true ;;
    *) return 1 ;;
  esac
  [ -n "$num" ] && [ "$num" != "null" ] && echo "$num" || true
}

vcs_pr_list_head() {   # <branch> — prints the first open PR/MR number from that branch, if any
  vcs_detect
  local branch="$1" num=""
  case "$VCS_PROVIDER" in
    github) num=$(gh pr list --head "$branch" --json number --jq '.[0].number' 2>/dev/null) || true ;;
    gitlab) num=$(glab mr list --source-branch "$branch" -F json 2>/dev/null | jq -r '.[0].iid // empty') || true ;;
    gitea)  num=$(tea pulls list --fields index,head --output json 2>/dev/null \
                    | jq -r --arg h "$branch" '[.[] | select(.head==$h)][0].index // empty') || true ;;
    *) return 1 ;;
  esac
  [ -n "$num" ] && [ "$num" != "null" ] && echo "$num" || true
}

vcs_pr_create() {   # <base> <head> <title> <body> — prints the new PR/MR's URL
  vcs_detect
  local base="$1" head="$2" title="$3" body="$4"
  case "$VCS_PROVIDER" in
    github) gh pr create --base "$base" --head "$head" --title "$title" --body "$body" ;;
    gitlab) glab mr create --target-branch "$base" --source-branch "$head" --title "$title" --description "$body" ;;
    gitea)  tea pulls create --base "$base" --head "$head" --title "$title" --description "$body" ;;
    *) echo "warn: no supported forge CLI detected/authenticated — skipping PR/MR creation" >&2; return 1 ;;
  esac
}

# ---- CLI dispatch (only when executed directly, not when sourced) --------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"; [ "$#" -gt 0 ] && shift
  case "$cmd" in
    detect)        vcs_detect; echo "$VCS_PROVIDER" ;;
    issue-create)  vcs_issue_create "$@" ;;
    issue-comment) vcs_issue_comment "$@" ;;
    issue-search)  vcs_issue_search "$@" ;;
    pr-list-head)  vcs_pr_list_head "$@" ;;
    pr-create)     vcs_pr_create "$@" ;;
    *) echo "usage: vcs.sh <detect|issue-create|issue-comment|issue-search|pr-list-head|pr-create> [args...]" >&2; exit 1 ;;
  esac
fi
