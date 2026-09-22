#!/usr/bin/env bash
# Provider model registry — the ONLY place in feature-team that maps a
# semantic model profile (strong/balanced/fast) to a concrete,
# provider-specific model identifier. Nothing else (role skills, the state
# machine, spawn scripts) should ever hardcode a model name — see
# feature-team/SKILL.md § Model selection.
#
# "strong"/"balanced"/"fast" are per-provider SELECTION PREFERENCES, not a
# claim of cross-provider equivalence: strong(claude) is not "the same
# model tier" as strong(openai) or strong(deepseek). Each just means "the
# configured stronger model for that provider in this environment."
#
# Resolution order for provider_profile_model <kind> <profile>:
#   1. <KIND>_<PROFILE>_MODEL           e.g. CODEX_STRONG_MODEL
#   2. <VENDOR-FAMILY>_<PROFILE>_MODEL  e.g. OPENAI_STRONG_MODEL (covers
#      every kind whose CLI is backed by that vendor, incl. kind-specific
#      variants like codex; see kind_vendor_family below)
#   3. repo config  providers.<vendor-family>.models.<profile>
#      (.feature-team/config.yaml — see config-lib.sh)
#   4. user config  providers.<vendor-family>.models.<profile>
#      (~/.config/feature-team/config.yaml)
#   5. the seed default below, if one is shipped for that vendor family
#   6. empty — callers MUST treat empty as "no opinion": fall through to
#      the provider's own CLI default (see agent-env.sh's
#      resolve_agent_args). Never substitute another provider's model or
#      another profile's model, and never silently switch provider.
#
# Profiles: top / strong / balanced / fast (highest reasoning/cost to
# lowest). "top" and "strong" MAY resolve to the same model for a vendor
# whose catalog only has three real tiers (e.g. Claude's opus/sonnet/haiku)
# — that is expected, not a bug: a profile is a selection preference, not a
# promise of a distinct model per tier.
#
# Seed defaults here are a starting point, not a promise — provider model
# catalogs change on their own schedule. Override per-environment via the
# env vars above rather than editing this file, unless you are
# intentionally changing the shipped default for everyone. A vendor family
# with no seed entry below simply resolves empty until configured; that is
# by design, not an omission to fix by guessing a model id.

# A herdr agent "kind" is a specific CLI, but several kinds are backed by
# the same vendor's model catalog under a different CLI-specific model
# *name* (e.g. codex, OpenAI's coding-agent CLI, wants "gpt-5-codex" rather
# than a raw API model id). This lets one OPENAI_STRONG_MODEL cover every
# such kind, while a kind-specific override still wins if both are set.
kind_vendor_family() {   # <kind>
  case "$1" in
    codex) echo openai ;;
    *) echo "$1" ;;
  esac
}

# Prints the configured model for <kind, profile>. Empty output (not an
# error) means "no opinion — the provider's own CLI default applies."
provider_profile_model() {   # <kind> <profile>
  local kind="$1" profile="$2" family kind_u profile_u family_u var val
  kind_u=$(printf '%s' "$kind" | tr '[:lower:]-' '[:upper:]_')
  profile_u=$(printf '%s' "$profile" | tr '[:lower:]-' '[:upper:]_')
  family=$(kind_vendor_family "$kind")
  family_u=$(printf '%s' "$family" | tr '[:lower:]-' '[:upper:]_')

  var="${kind_u}_${profile_u}_MODEL"; val="${!var:-}"
  [ -n "$val" ] && { echo "$val"; return 0; }

  if [ "$family_u" != "$kind_u" ]; then
    var="${family_u}_${profile_u}_MODEL"; val="${!var:-}"
    [ -n "$val" ] && { echo "$val"; return 0; }
  fi

  # Config-defined provider catalogs (see config-lib.sh) — repo before user,
  # same precedence as everything else repo-vs-user. Only consulted if
  # config-lib.sh happens to be loaded (agent-env.sh always loads it first,
  # but this file may in principle be sourced standalone).
  if command -v cfg_get_repo >/dev/null 2>&1; then
    val=$(cfg_get_repo "providers.$family.models.$profile")
    [ -n "$val" ] && { echo "$val"; return 0; }
  fi
  if command -v cfg_get_user >/dev/null 2>&1; then
    val=$(cfg_get_user "providers.$family.models.$profile")
    [ -n "$val" ] && { echo "$val"; return 0; }
  fi

  case "$family:$profile" in
    # The claude CLI resolves these aliases to its own current model
    # itself — deliberately not a dated model id, so this line never goes
    # stale the way a pinned id would. Claude's catalog only has three real
    # tiers, so "top" and "strong" both mean "the strongest available".
    claude:top)        echo "opus" ;;
    claude:strong)     echo "opus" ;;
    claude:balanced)   echo "sonnet" ;;
    claude:fast)       echo "haiku" ;;
    # DeepSeek's API has exposed exactly these two model names for a long
    # time; deepseek-reasoner is its stronger/slower reasoning model. Same
    # two-tier reality as Claude above — "top" aliases to "strong".
    deepseek:top)       echo "deepseek-reasoner" ;;
    deepseek:strong)   echo "deepseek-reasoner" ;;
    deepseek:balanced) echo "deepseek-chat" ;;
    deepseek:fast)     echo "deepseek-chat" ;;
    # No seed default for openai/gemini/other vendors: their model catalogs
    # rotate too fast to guess confidently here. Configure
    # <FAMILY>_<PROFILE>_MODEL (e.g. OPENAI_STRONG_MODEL, GEMINI_FAST_MODEL),
    # a providers.<family>.models.<profile> entry in either config scope, or
    # accept the provider's own CLI default.
    *) echo "" ;;
  esac
}
