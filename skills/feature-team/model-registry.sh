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
#   3. the seed default below, if one is shipped for that vendor family
#   4. empty — callers MUST treat empty as "no opinion": fall through to
#      the provider's own CLI default (see agent-env.sh's
#      resolve_agent_args). Never substitute another provider's model or
#      another profile's model, and never silently switch provider.
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

  case "$family:$profile" in
    # The claude CLI resolves these aliases to its own current model
    # itself — deliberately not a dated model id, so this line never goes
    # stale the way a pinned id would.
    claude:strong)     echo "opus" ;;
    claude:balanced)   echo "sonnet" ;;
    claude:fast)       echo "haiku" ;;
    # DeepSeek's API has exposed exactly these two model names for a long
    # time; deepseek-reasoner is its stronger/slower reasoning model.
    deepseek:strong)   echo "deepseek-reasoner" ;;
    deepseek:balanced) echo "deepseek-chat" ;;
    deepseek:fast)     echo "deepseek-chat" ;;
    # No seed default for openai/gemini/other vendors: their model catalogs
    # rotate too fast to guess confidently here. Configure
    # <FAMILY>_<PROFILE>_MODEL (e.g. OPENAI_STRONG_MODEL, GEMINI_FAST_MODEL)
    # for these, or accept the provider's own CLI default.
    *) echo "" ;;
  esac
}
