---
name: feature-team
description: "Fire-and-forget dev team (PM → SA → Dev → Tester) as Herdr agents of any supported kind (pi, claude, codex, gemini, cursor, …) — by default, every role runs as the SAME agent/provider that invoked this skill (no hardcoded default provider; see § Provider inheritance). The PM owns the task end-to-end through an explicit state machine, checkpointing every transition to docs/features/<slug>.md and a mirrored tracking issue (GitHub, GitLab, or Gitea — whichever forge `origin` points at); the user walks away and gets one notification when the feature reaches done/blocked/failed. Use for new feature requests, e.g. '/feature-team add bulk export'. Requires running inside Herdr."
---

# Feature Team (Herdr) — fire-and-forget

The user submits a request and walks away. **PM owns the task**: PM drives SA → Dev → Tester through an explicit state machine, checkpoints every transition to the tracking doc and issue, and fires exactly one terminal notification. You (this session) only: set up the team, hand the request to PM, tell the user where it's tracked, and relay one summary when PM finishes. Never ask the user to watch panes or approve prompts.

The roles are agent-kind agnostic — the team can be all `claude`, all `codex`, all `pi`, or mixed. Kind and CLI flags are configuration (see Setup); nothing in this skill assumes a particular agent CLI beyond the defaults for `claude` (claude's own adapter — see Provider inheritance).

**By default, feature-team uses the same agent/provider that invoked it.** If you are Pi and you run `/feature-team`, PM/SA/Dev/Tester all default to `pi`. If you are Claude, they all default to `claude`. If you are Codex, they all default to `codex`. This is never a hardcoded default — see Provider inheritance below.

Scratch files stay in the repo: never write to `/tmp` or other system temp dirs. Concise notes/findings/status go in the tracking doc's Progress Log or a forge comment — that's what the user actually watches. Detailed evidence a worker produces (full test output, a Tester or Dev report) is exactly what `.tmp/` at the repo root is for (create it if missing; it should not be committed — add it to `.gitignore` if not already ignored): write it there as `.tmp/<role>-report-<n>.md` (see feature-handoff) and have the doc's Progress Log reference the path instead of inlining the content.

**Design principle this skill follows**: anything that can be enforced deterministically (state transitions, notification idempotency, git isolation, doc formatting) is a script, not a paragraph of instructions an LLM has to remember to follow the same way every time. The scripts below are load-bearing; the PM briefing only covers judgment calls a script can't make.

## Scripts in this directory

| script | purpose |
| --- | --- |
| `spawn-team.sh` | one-shot: create workspace + panes, start pm/sa/dev/tester |
| `spawn-agent.sh` | spawn a helper in a pane that **shares** the caller's working tree — sequential or read-only work only |
| `spawn-workstream.sh` | spawn a worker for an **independent, concurrent** code-writing workstream in its own Git worktree — resume-safe (reopens instead of duplicating) |
| `remove-workstream.sh` | tear down a workstream's worktree; refuses if it has uncommitted or unmerged work unless `--force` |
| `checkpoint.sh` | append a structured Progress Log stamp + update `\`\`\`state` fields in the tracking doc, in one call |
| `notify.sh` | fire the terminal notification exactly once per feature (checks/sets `notified` in the doc) |
| `vcs.sh` | forge-agnostic issue/PR operations — detects GitHub/GitLab/Gitea from `origin` and drives `gh`/`glab`/`tea` accordingly |
| `role-skill.sh` | print the absolute path of a role contract (`pm`/`sa`/`dev`/`tester`/`reviewer`/`handoff`/`git`/`security`), or `--json` for all |
| `model-registry.sh` | maps `<provider, model profile>` → a concrete model id; sourced by `agent-env.sh` (see § Model selection) — the ONLY place provider model ids live |
| `config-lib.sh` | reads the user-level (`~/.config/feature-team/config.yaml`) and repository-level (`.feature-team/config.yaml`) configuration scopes — the ONLY place either file is parsed (see § Configuration scopes); sourced by `agent-env.sh` |
| `config.sh` | the `feature-team config show`/`save` CLI (see § Configuration display and § Explicit "remember" behavior) |
| `test-provider-inheritance.sh` | regression test for provider-inheritance precedence/detection (see Provider inheritance) AND model-profile/registry resolution (see Model selection) — run it after touching `agent-env.sh`/`spawn-team.sh`'s kind or model resolution, or `model-registry.sh` |
| `test-model-config.sh` | regression test for the configuration-scope resolver: repo/user config precedence, connections, complexity policy, reviewer enablement, feature persistence/escalation, and secret-safety (see § Configuration scopes) — run it after touching `config-lib.sh`, `config.sh`, or the `resolve_role_*`/`resolve_model_profile` functions in `agent-env.sh` |
| `templates/feature-doc.md` | the tracking-doc skeleton (state machine, acceptance criteria, DoD, resume state) |

All of them accept `-h`/malformed-arg errors verbatim from `herdr`/`git` — no retry logic hides a real failure.

## Role contracts (sibling skills)

This skill owns *orchestration*. How an agent should behave **as** a role lives in separate skills next to this one:

| skill | owns |
| --- | --- |
| `feature-pm` | feature lifecycle: criteria, ambiguity, coordination judgment, resume reconciliation, retry/done/blocked calls, escalation |
| `feature-sa` | architecture and technical design, grounded in the existing repo |
| `feature-dev` | implementation of one assigned workstream |
| `feature-tester` | independent verification and the PASS/FAIL evidence format |
| `feature-reviewer` | optional final independent review (architecture fidelity, security, unintended changes, test coverage, maintainability, regression risk) — only runs when enabled, see § Optional Reviewer role |
| `feature-handoff` | the shared PM↔worker message format (both directions) |
| `feature-git` | shared Git safety rules (branches, worktrees, diffs, resume safety) |
| `feature-security` | shared rules on secrets, production, permissions, workspace boundaries |

**Loading is provider-agnostic**: agents read the file at an absolute path — the one mechanism every agent kind has. Nothing depends on a provider's own skill loader. `spawn-team.sh` resolves the paths (siblings of this directory, else `.claude/skills/`, else `$CLAUDE_CONFIG_DIR/skills/`) and reports them as `role_skills` in its JSON; `role-skill.sh` re-derives them later (a respawned PM after a crash, or a workstream worker). If a contract is missing, both warn loudly and the run falls back to the condensed role summary in the briefing below.

Keep the split: never move spawn commands, state transitions, notification, PR, or workspace lifecycle into a role skill, and never move role judgment back into here.

## Preflight

```bash
test "${HERDR_ENV:-}" = 1 || fallback
```

If not inside Herdr, run PM → SA → Dev → Tester yourself — via your host's own subagent mechanism if it has one (e.g. Claude Code: Plan for SA, general-purpose for the rest), otherwise sequentially in this session — tracking in the same docs/issue format (copy `templates/feature-doc.md`), and report inline. The role contracts still apply: load the one for whichever role you are acting as (`bash "$SKILL_DIR/role-skill.sh" <role>`), and keep the boundaries — especially Tester's independence from Dev — even when every role is you. `spawn-workstream.sh`/`remove-workstream.sh` require Herdr's `worktree` command group; without it, parallel workstreams fall back to sequential work in one working tree.

## Provider inheritance

The calling agent/provider is the default execution provider for the entire team. The provider flows through every layer:

```
CALLER_AGENT → TEAM_KIND → PM_KIND / SA_KIND / DEV_KIND / TESTER_KIND
```

Effective precedence for each role, highest first (this is the KIND half of
the full chain in § Configuration precedence — the MODEL half is § Model
selection below):

```
role-specific override (PM_KIND/SA_KIND/DEV_KIND/TESTER_KIND/REVIEWER_KIND)
    > team-level override (TEAM_KIND)
    > role-specific connection (<ROLE>_CONNECTION -> its configured kind)
    > team-level connection (TEAM_CONNECTION -> its configured kind)
    > repository config's connection for this role (.feature-team/config.yaml)
    > user config's connection for this role (~/.config/feature-team/config.yaml)
    > calling agent/provider (detected, or $FEATURE_TEAM_CALLER_KIND)
    > fail — no provider is ever silently chosen
```

A **connection** (`com1`, `com2`, ...) is a named account/CLI binding defined
only in user config; a role/team config that names one resolves it to a kind
+ provider (see § Configuration scopes and § Strict separation of concepts).
A referenced connection that isn't defined is always a hard failure
(`MODEL_UNAVAILABLE`), never a fallback to the next tier or another provider
(see § Detect configuration drift).

Examples (caller = pi):

| config | result |
| --- | --- |
| none | PM=pi SA=pi DEV=pi TESTER=pi |
| `DEV_KIND=claude` | PM=pi SA=pi **DEV=claude** TESTER=pi |
| `TEAM_KIND=codex` | PM=codex SA=codex DEV=codex TESTER=codex |
| `TEAM_KIND=codex TESTER_KIND=gemini` | PM=codex SA=codex DEV=codex **TESTER=gemini** |
| repo config: `roles.dev.connection: com2` (com2=deepseek) | PM=pi SA=pi **DEV=deepseek** TESTER=pi |

Explicit configuration always wins — setting some roles explicitly does not normalize the rest back to the caller's provider; unset roles still inherit the caller.

### How the caller's kind is determined

`detect_caller_kind` in `agent-env.sh`, in order:
1. `$FEATURE_TEAM_CALLER_KIND` — set this yourself if you know your own kind and want to guarantee correct detection (recommended for any agent kind not covered by #2, e.g. Pi): `export FEATURE_TEAM_CALLER_KIND=pi`.
2. Well-known runtime signals checked automatically: `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT` → `claude`; `CODEX_SANDBOX*` → `codex`; `CURSOR_TRACE_ID` → `cursor`; a generic `AI_AGENT` slug some terminal integrations set (e.g. Warp) → parsed for a known provider prefix.
3. If nothing matches: undetected. The spawn scripts then fail with `Unable to determine calling agent provider. Set TEAM_KIND explicitly, or export FEATURE_TEAM_CALLER_KIND=<kind>.` — **never a silent claude fallback.**

Provider identity is a runtime concern, never inferred from the repo (no scanning for `.claude/`, no guessing from language/framework/installed binaries).

## Model selection

### Strict separation of concepts

Five independent concepts, never conflated and never used interchangeably:

```
Role          PM / SA / DEV / TESTER / (optional) REVIEWER — a fixed
              contract (feature-pm/sa/dev/tester/reviewer); never changes
              with the model
Connection    a named account/CLI binding on THIS machine (com1, com2, ...)
              — defined only in user config; never in repo config (see
              § Repository portability)
Provider      the agent kind's own vendor (claude, openai, deepseek,
              gemini, ...) — a connection resolves to exactly one
Model Profile top / strong / balanced / fast — a semantic *selection
              preference*, not a model name
Model         a provider-specific identifier ("opus", "gpt-5.1",
              "deepseek-reasoner", ...)
```

```
Role → Connection → Provider → Model Profile → Model
```

`top`/`strong`/`balanced`/`fast` are per-provider *selection preferences*,
never a cross-provider equivalence claim — `top` on Claude and `top` on
DeepSeek are each "the configured strongest model for that provider," not
"the same tier of model." A vendor with only three real tiers may resolve
`top` and `strong` to the same model id — that's expected, not a bug. Role
skills (`feature-pm`/`sa`/`dev`/`tester`/`reviewer`) never mention a
connection, provider, profile, or model name — see § Recommended default
model policy.

### Recommended default model policy

Cost optimization, not "cheapest possible" (see § Do not over-optimize
below) — spend reasoning budget where an error is most expensive to
discover late:

```yaml
roles:
  pm:       { profile: strong }    # scope/acceptance-criteria/orchestration judgment
  sa:       { profile: top }       # architecture — a wrong call here gets implemented AND "tested"
  dev:      { profile: balanced }  # constrained by SA's design + acceptance criteria
  tester:   { profile: balanced }  # constrained by the criteria + the actual diff
  reviewer: { profile: strong }    # optional — see § Optional Reviewer role
```

A wrong SA decision propagates into Dev's implementation and Tester's
verification of the *wrong target* — the most expensive kind of error to
catch late — so SA defaults to `top`, one tier above PM. Reviewer is
optional; most features run with no Reviewer at all, which is normal, not
a gap (§ Optional Reviewer role).

### Do not over-optimize by using weak models everywhere

The goal is **minimum model cost that maintains sufficient quality**, not
the cheapest model for every role. Don't default every role to `fast` to
save cost, and don't default every role to `top` "to be safe" either —
both defeat the point of having profiles at all. Escalate a specific
role/feature/retry when its actual risk warrants it (§ Model escalation),
rather than permanently over- or under-provisioning every run.

### Configuration scopes

Three scopes, layered — **never confuse them**:

```
User config    = global preference,  ~/.config/feature-team/config.yaml
Repo config    = project preference, .feature-team/config.yaml
Feature config = immutable run config, docs/features/<slug>.md's ```state block
```

**User config** (`~/.config/feature-team/config.yaml`) — applies to every
repository unless overridden. This is the ONLY place `connections:` are
defined (a connection names a provider, and optionally a `kind:` when the
provider's vendor name differs from its herdr CLI kind, e.g. `provider:
openai` needs `kind: codex`):

```yaml
version: 1
connections:
  com1:
    provider: openai
    kind: codex        # optional; defaults to the provider name as the kind
  com2:
    provider: deepseek
defaults:
  roles:
    pm:     { connection: com1, profile: strong }
    sa:     { connection: com1, profile: top }
    dev:    { connection: com2, profile: balanced }
    tester: { connection: com2, profile: balanced }
providers:                       # optional: config-defined model catalogs,
  openai:                        # an alternative to <VENDOR>_<PROFILE>_MODEL
    models: { top: gpt-5.1, strong: gpt-5.1, balanced: gpt-5.1-mini }
```

**Repo config** (`.feature-team/config.yaml`, at the repository root) —
overrides user config for this repository only. References connections by
name; never redefines them (§ Repository portability):

```yaml
version: 1
complexity: normal               # simple|normal|complex|high-risk — see below
reviewer:
  enabled: false
  profile: strong
roles:
  dev: { connection: com2, profile: balanced }
```

**Feature config** (`docs/features/<slug>.md`'s `\`\`\`state` block) — the
immutable snapshot of what THIS feature actually started with; see
§ Feature-level model persistence.

### Configuration precedence

For KIND/CONNECTION and for PROFILE, highest first (mirrors § Provider
inheritance's kind-only table above):

```
1. explicit CLI/invocation override   <ROLE>_KIND, <ROLE>_CONNECTION,
                                       <ROLE>_MODEL_PROFILE, <ROLE>_MODEL,
                                       TEAM_KIND/TEAM_CONNECTION/TEAM_MODEL_PROFILE
2. feature-specific persisted config   docs/features/<slug>.md's ```state
                                       block, reapplied as an explicit
                                       override when PM respawns a role
3. repository config                   .feature-team/config.yaml
4. user config                         ~/.config/feature-team/config.yaml
5. caller/provider inheritance         detect_caller_kind (§ Provider inheritance)
6. built-in role defaults              role_default_profile (§ Recommended
                                       default model policy, adjusted by
                                       § Task-complexity policy)
```

A repo config `roles.<role>.model` (only present after `config.sh save` —
§ Explicit "remember" behavior) acts like an explicit model pin at tier 3,
but ONLY if its recorded `roles.<role>.provider` still matches the role's
actually-resolved provider — a provider change (someone repointed the
connection, or overrode `<ROLE>_KIND`) never silently reuses a stale
pinned model id; the profile-based resolution takes over instead, with a
warning.

Explicit configuration always wins. A referenced connection that isn't
defined anywhere is always a hard failure (`MODEL_UNAVAILABLE`), never a
silent fallback to the next tier or another connection/provider (§ Detect
configuration drift).

### Task-complexity policy

Optional, explicit, never inferred from vague signals — `$FEATURE_COMPLEXITY`
or the repo config's `complexity:` field, default `normal`:

```
              PM       SA     DEV          TESTER   REVIEWER
simple        strong   strong fast         fast     strong
normal        strong   top    balanced     balanced strong
complex       strong   top    balanced*    strong   strong
high-risk     strong   top    strong       strong   strong (or top)
```

*complex's DEV defaults to `balanced`; escalate to `strong` explicitly for a
specific feature if its actual risk warrants it — don't make `complex`
mean "everything gets a bigger model" by default.

This table is only the **built-in default** tier (precedence tier 6) — an
explicit override, repo config, or user config profile for a role always
wins over it. Security-sensitive changes, authN/authZ, financial
transactions, cryptography, destructive migrations, and major architecture
changes may justify `high-risk` — set it explicitly per feature; this skill
never escalates complexity on its own from keyword-matching the request.

### Caller provider inheritance

When no connection/config supplies a role's provider, it inherits whichever
agent/CLI invoked feature-team (§ Provider inheritance) — never a
hardcoded kind, and never partially: an unset role always inherits the
caller, even when other roles are explicitly configured.

```
Caller: Pi + OpenAI, repo config: dev.connection: com2 (com2 = deepseek)
  PM      → inherited OpenAI / strong
  SA      → inherited OpenAI / top
  DEV     → DeepSeek / balanced     (from repo config)
  TESTER  → inherited OpenAI / balanced
```

### Why PM/SA/Reviewer default to a stronger profile

PM owns requirements interpretation, scope, acceptance criteria,
orchestration, retries, and lifecycle decisions; SA owns architecture,
system impact, API/data design, security tradeoffs, and migration design —
and defaults one tier higher than PM (`top`) because a wrong architecture
call is the most expensive kind of error to discover late (§ Recommended
default model policy). Reviewer (when enabled) is an independent second
opinion, so it defaults to `strong` too. Dev and Tester's tasks are
narrower and more constrained (by the acceptance criteria + SA's design +
existing code + a test plan), so a smaller/cheaper model is *often*
sufficient — but not always; escalate per-feature when it isn't (below).

### Examples

Caller = Pi, provider = OpenAI, no explicit overrides, no config files:

```
PM      → OpenAI's configured "strong" model
SA      → OpenAI's configured "top" model
DEV     → OpenAI's configured "balanced" model
TESTER  → OpenAI's configured "balanced" model
```

Mixed providers via connections (user config defines `com1`=claude,
`com2`=deepseek; repo config picks per role — explicit configuration only,
never automatic):

```yaml
# .feature-team/config.yaml
roles:
  sa:  { connection: com1, profile: strong }
  dev: { connection: com2, profile: balanced }
```
```
# → PM=<caller>, SA=claude strong, DEV=deepseek balanced, TESTER=<caller> balanced
```

Or the equivalent one-off, without touching any config file:

```bash
SA_KIND=claude   SA_MODEL_PROFILE=strong \
DEV_KIND=deepseek DEV_MODEL_PROFILE=balanced \
bash "$SKILL_DIR/spawn-team.sh" bulk-export
```

Cost/quality tradeoff, orchestration unchanged either way:

```
DEV_MODEL_PROFILE=fast TESTER_MODEL_PROFILE=fast     # cheaper
DEV_MODEL_PROFILE=strong TESTER_MODEL_PROFILE=strong # highest quality
```

### Model escalation

PM may escalate a role's profile for a specific feature or retry — always
an explicit decision, never automatic from a vague difficulty heuristic,
and scoped to the current feature/retry only unless explicitly saved to
repo config (§ Explicit "remember" behavior):

```
Feature A:            Repository default:
  DEV → balanced         DEV → balanced   (unchanged — A's escalation
  retry 2 → strong                         never rewrites this)
```

To escalate mid-run (e.g. after a Tester-caught defect), set
`AGENT_MODEL_PROFILE=strong` (or `AGENT_MODEL=<explicit>`) before
respawning that worker via `spawn-agent.sh`/`spawn-workstream.sh`, record
the new `<role>_kind`/`<role>_connection`/`<role>_provider`/`<role>_model`
in the doc's `\`\`\`state` block, and checkpoint the change explicitly —
STAGE `SYSTEM`, STATUS `MODEL_ESCALATED`:

```
bash <skill_dir>/checkpoint.sh docs/features/<slug>.md SYSTEM MODEL_ESCALATED \
  --summary "Dev was escalated from balanced to strong after repeated implementation/verification failures." \
  --result "Retry will use the stronger configured model." --next "Dev retry." \
  --set dev_profile=strong --set dev_model=<new model>
```

Never change a role's model silently — this checkpoint IS the "never
silently switch" contract, not optional bookkeeping.

### Optional Reviewer role

Disabled by default (`reviewer.enabled: false` in repo config, or
`$REVIEWER_ENABLED`). When enabled, a 5th agent runs after Tester's PASS:

```
PM → SA → DEV → TESTER → REVIEWER → PR
```

Reviewer independently inspects the actual diff, acceptance criteria,
architecture fidelity against SA's design, security, unintended changes,
test coverage, maintainability, and regression risk — it does not re-verify
what Tester already proved, and never relies solely on Dev's or Tester's
reports (see `feature-reviewer`). Reviewer's verdict is `APPROVE` /
`CHANGES_REQUESTED` / `ESCALATE`, mirroring Tester's PASS/FAIL/BLOCKED
shape. Do NOT require every project to use a Reviewer — most features have
none, and that is the normal case.

### Feature-level model persistence

`spawn-team.sh`'s JSON output (`kinds`/`connections`/`providers`/
`model_profiles`/`models`/`sources`/`complexity`/`reviewer_enabled`) is what
PM records into `docs/features/<slug>.md`'s `\`\`\`state` block at kickoff
(§ PM briefing) — this becomes the feature's own immutable configuration.
If the repository's or user's config changes while this feature is still
running, the feature keeps its already-persisted configuration; it is never
silently re-resolved against the new config on resume. `spawn-team.sh` also
exports the resolved values into the team's own panes so a PM that later
calls `spawn-agent.sh`/`spawn-workstream.sh` for a crash-respawn or a retry
reuses the feature's actual configuration instead of re-deriving (or
losing) it. Resume reuses each role's persisted values unless the user
changes it or PM explicitly escalates it (checkpointed as `MODEL_ESCALATED`
above) — record a resume that reuses persisted config as its own stamp too
(STAGE `SYSTEM`, STATUS `RESUMED` or as part of the PM `RESUMED` stamp),
so it's visible that no drift occurred silently.

### Explicit "remember" behavior

```bash
bash "$SKILL_DIR/config.sh" show              # print the effective config (see below)
bash "$SKILL_DIR/config.sh" save              # persist it to .feature-team/config.yaml
bash "$SKILL_DIR/config.sh" remember-models   # alias of save
```

`save`/`remember-models` computes the same effective configuration `show`
displays and writes it to `.feature-team/config.yaml`, including each
role's resolved connection/provider/profile/model and a `model_policy`
block recording `source: repository` and `updated_at`. This is a **stable**
operation, not something that runs on every spawn: `spawn-team.sh` reads
repo config but never rewrites it. Run `save` explicitly when the user
wants this repository's model setup to stick. It is non-interactive — an
explicit command needs no confirmation prompt; if a caller wants user
confirmation first, show the table (`config.sh show`) and ask before
running `save`, rather than building confirmation into the script itself.

### Repository config should not contain secrets

`.feature-team/config.yaml` may contain a connection name, provider,
profile, model id, and other non-secret configuration — never an API key,
token, password, or private key. Connections resolve to credentials through
each provider's own credential store or environment-based auth, never
through this file. If local-only secrets/config are ever needed, they
belong in `.feature-team/config.local.yaml`, which is gitignored (see
`.gitignore`) — never `.feature-team/config.yaml`, which is committed.

### Repository portability

Repo config must never depend on a user's machine-specific path or
launcher binary (bad: `launcher: /Users/alice/bin/my-agent`). It references
a `connection`/`provider`/`profile` only — provider-specific launcher
resolution happens through `model-registry.sh`/`resolve_agent_args`, the
provider-adapter layer, never through a path baked into repo config. This
is also why `connections:` live only in user config (§ Configuration
scopes): a connection is a statement about THIS machine's account/CLI
setup, which is never portable across machines the way a repo is.

### Detect configuration drift

At feature start (and whenever `resolve_role_kind` runs), a role's
connection/kind is validated, not assumed:

- a connection name referenced by repo or user config that isn't defined
  anywhere fails immediately with `MODEL_UNAVAILABLE`, naming the role, the
  connection, and where it was configured — never silently substituting
  another connection or provider
- a resolved kind unknown to this herdr install (`validate_kind`) fails the
  same way, before any pane is created

Checkpoint a `MODEL_UNAVAILABLE` failure (STAGE `SYSTEM`) rather than
retrying with a different provider silently — same principle as the
kind-detection fail path in § Provider inheritance.

### Configuration display

```bash
bash "$SKILL_DIR/config.sh" show
```

```
Repository: ~/projects/my-app
User config: ~/.config/feature-team/config.yaml
Repo config: ~/projects/my-app/.feature-team/config.yaml
Complexity: normal
Reviewer: disabled

Role       Connection   Provider    Profile     Model            Source
pm         com1         openai      strong      gpt-5.1          user
sa         com1         openai      top         gpt-5.1          repository
dev        com2         deepseek    balanced    deepseek-chat    repository
tester     com2         deepseek    balanced    deepseek-chat    user
```

`Source` names where each role's effective binding actually came from
(`cli`/`repository`/`user`/`caller`/`default`), so precedence is debuggable
at a glance instead of inferred. Never displays secrets — the only fields
involved are role, connection name, provider, profile, and model id.

### Retry and resume

`spawn-team.sh` exports the resolved `PM_MODEL`/`SA_MODEL`/`DEV_MODEL`/
`TESTER_MODEL`/`REVIEWER_MODEL` (and their `*_MODEL_PROFILE`s) into the
team's own panes, the same way it exports the resolved kinds — so a PM
that later calls `spawn-agent.sh`/`spawn-workstream.sh` for a crash-respawn
or a retry reuses the team's actual configuration instead of re-deriving
(or losing) it. A resumed feature keeps each role's persisted
`*_kind`/`*_connection`/`*_provider`/`*_profile`/`*_model` (§ Resume state
in templates/feature-doc.md; § Feature-level model persistence above)
unless the user changes it or PM explicitly escalates it.

### Progress Log entries for model configuration

Model configuration changes appear in the Progress Log only when relevant
— never one entry per model invocation:

- **initial effective configuration** — STAGE `SYSTEM`, STATUS
  `MODEL_CONFIGURED`, logged once at kickoff (see § PM briefing's STARTED
  checkpoint, which folds this in)
- **explicit model change / escalation** — STAGE `SYSTEM`, STATUS
  `MODEL_ESCALATED` (§ Model escalation above)
- **provider switch** — an explicit reconfiguration mid-run; checkpoint it
  the same way as an escalation, naming old and new provider
- **configuration error** — STAGE `SYSTEM`, STATUS `MODEL_UNAVAILABLE` (§
  Detect configuration drift above)
- **resume with persisted model configuration** — folded into the PM
  `RESUMED` stamp; call out explicitly if the repo/user config has since
  diverged from what this feature is still using, so a reader understands
  why it doesn't match `config.sh show`'s current output

## Verification strategy

Mirrors § Model selection: verification is a per-feature strategy, not a fixed rule, and neither concept below is ever hardcoded to a specific tool.

```
Verification level   static / unit / integration / contract / e2e / manual —
                      chosen per acceptance criterion, for the minimum
                      confidence that criterion needs; never "e2e for
                      everything" and never skipped for a criterion that
                      genuinely needs it
Test framework        whatever this repository already uses — discovered,
                      never assumed (no default to Playwright, Cypress,
                      pytest, npm test, or any other named tool)
```

SA proposes the initial strategy while planning (feature-sa's `## Verification strategy` output section); PM records it into the doc's `## Verification Strategy` section and the per-criterion `[level: ..., required: ...]` tags (see `templates/feature-doc.md`) before Dev starts. Tester re-confirms or adjusts it during verification — Tester is the one actually running checks against the real diff, and may find a level insufficient (or more than needed) once it exists.

E2E is a *conditional* requirement, not a default: it applies only when a user-facing/multi-step workflow, an explicit acceptance criterion, or a Tester-identified risk needs it. A feature with no such criterion needs no E2E block at all — omit it from the doc rather than writing `required: no` everywhere.

Discovering the repo's actual E2E framework (or confirming none exists) is SA's job at planning and Tester's job at verification, both via the same discovery list (feature-sa § Inspect before you design, feature-tester § Discover the repo's own commands): package manifest, `Makefile`/`Taskfile`/`justfile`, README/CONTRIBUTING, CI config, test directories, and framework-specific config files (`playwright.config.*`, `cypress.config.*`, or whatever else the repo actually uses). If E2E is required and no framework exists, that is a flag to PM (feature-sa § Flagging, feature-tester's Report `recommendation: ESCALATE`) — introducing a new E2E framework is an infrastructure decision, never something SA or Tester adopts unilaterally.

## Setup — one command

Run the spawn script (next to this skill; `$SKILL_DIR` below is its directory). It captures this session's provider/config env, creates a `feature: <slug>` workspace, lays out four panes, starts the starters (`pm`/`sa`/`dev`/`tester`), and waits for them to boot:

```bash
bash "$SKILL_DIR/spawn-team.sh" <slug>
```

The final JSON line gives `workspace`, each agent's `pane` id, each agent's `kind`, `caller_kind` (what was detected/declared, or `null`), `default_branch` (detected from the repo, not assumed to be `main`), `skill_dir` (use that absolute path in the PM briefing), and `role_skills` (absolute path per role contract — substitute these into the briefing too). Agent-name collisions (a rerun while starters are alive) fail fast with herdr's error — rename or close the old workspace first. The script also logs `[TEAM] caller=... pm=... sa=... dev=... tester=...` to stderr so a failed/unexpected provider choice is diagnosable without secrets ever appearing in the log.

Configuration (env vars, all optional):

| var | effect |
| --- | --- |
| `FEATURE_TEAM_CALLER_KIND` | declare the calling agent's own kind explicitly (see Provider inheritance); only needed when automatic detection doesn't cover your agent |
| `TEAM_KIND` | agent kind for every role (default: the calling agent's own kind — **never** a hardcoded default); any kind `herdr agent` lists |
| `PM_KIND` `SA_KIND` `DEV_KIND` `TESTER_KIND` `REVIEWER_KIND` | per-role kind override |
| `TEAM_CONNECTION` | named connection (see user config's `connections:`) for every role without a more specific override — resolves to a kind + provider |
| `PM_CONNECTION` `SA_CONNECTION` `DEV_CONNECTION` `TESTER_CONNECTION` `REVIEWER_CONNECTION` | per-role connection override |
| `TEAM_ARGS` | args passed verbatim to every agent CLI after `--` |
| `PM_ARGS` `SA_ARGS` `DEV_ARGS` `TESTER_ARGS` `REVIEWER_ARGS` | per-role args override |
| `PM_MODEL` `SA_MODEL` `DEV_MODEL` `TESTER_MODEL` `REVIEWER_MODEL` | explicit model id per role — wins over everything below (see § Model selection) |
| `PM_MODEL_PROFILE` `SA_MODEL_PROFILE` `DEV_MODEL_PROFILE` `TESTER_MODEL_PROFILE` `REVIEWER_MODEL_PROFILE` | semantic profile (`top`/`strong`/`balanced`/`fast`) per role |
| `TEAM_MODEL_PROFILE` | semantic profile for every role without its own override (default when unset, before repo/user config: PM=`strong`, SA=`top`, DEV/TESTER=`balanced`, REVIEWER=`strong`) |
| `<KIND>_<PROFILE>_MODEL` / `<VENDOR>_<PROFILE>_MODEL` | provider-scoped model config, e.g. `CLAUDE_STRONG_MODEL`, `OPENAI_BALANCED_MODEL`, `DEEPSEEK_FAST_MODEL` — see `model-registry.sh` (or a `providers.<vendor>.models.<profile>` entry in either config scope) |
| `FEATURE_TEAM_USER_CONFIG` | path to the user config file (default `~/.config/feature-team/config.yaml`) — mainly for tests/alternate profiles |
| `FEATURE_COMPLEXITY` | `simple`/`normal`/`complex`/`high-risk` (default: repo config's `complexity:`, else `normal`) — see § Task-complexity policy |
| `REVIEWER_ENABLED` | `1`/`true` to add the optional Reviewer agent (default: repo config's `reviewer.enabled`, else off) — see § Optional Reviewer role |
| `TEAM_ENV_PREFIXES` `TEAM_ENV_KEYS` `TEAM_ENV_DENY` | which env vars reach the team's panes (see `agent-env.sh`) |
| `FEATURE_GIT_PROVIDER` | force the forge (`github`/`gitlab`/`gitea`) instead of auto-detecting it from `origin`'s hostname — needed for a self-hosted instance on a domain that doesn't contain "github"/"gitlab"/"gitea" (see `vcs.sh`) |
| `TEAM_MAX_RETRIES` | default `3` — max Dev↔Tester fix/re-verify cycles per workstream before PM must mark `blocked`/`failed` |
| `TEAM_MAX_PARALLEL` | default `4` — max concurrent workstreams (beyond the always-sequential `main`) |
| `TEAM_STAGE_TIMEOUT_MS` | default `600000` — the timeout PM should pass to `herdr agent prompt --wait` for SA/Dev/Tester turns |

With no `*_ARGS`, kind `claude` starts as `--model <resolved model> --permission-mode auto` and kind `codex` as `--model <resolved model> --full-auto` (or bare `--full-auto` if no model resolved) — the two provider adapters this skill has confirmed CLI syntax for. **Any other kind starts bare unless a model was actually resolved for it via configuration**, in which case it gets a best-effort `--model <resolved model>` — the script never guesses auto-approve flags for an unconfirmed CLI, so pass those yourself, e.g.:

```bash
TEAM_KIND=codex TEAM_ARGS="--model gpt-5-codex --full-auto" bash "$SKILL_DIR/spawn-team.sh" bulk-export
```

Mixed example — caller is Pi, SA runs on Claude and Dev on Codex, everything else inherits Pi:

```bash
SA_KIND=claude SA_ARGS="--model opus --permission-mode auto" \
DEV_KIND=codex DEV_ARGS="--model gpt-5-codex --full-auto" \
bash "$SKILL_DIR/spawn-team.sh" bulk-export
# → PM=pi SA=claude DEV=codex TESTER=pi
```

If the user names a kind without its flags, ask for the flags once (or check that CLI's `--help`) rather than starting agents that stop on every approval.

If the calling agent's kind cannot be detected and nothing was configured explicitly, the script fails immediately with no panes created:

```
Unable to determine calling agent provider.
Set TEAM_KIND explicitly, or export FEATURE_TEAM_CALLER_KIND=<kind> (pi, claude, codex, gemini, cursor, ...) before invoking this script.
```

`spawn-agent.sh` and `spawn-workstream.sh` (used mid-run by PM for helpers/workstreams) follow the identical precedence (`AGENT_KIND` > `TEAM_KIND` > caller kind > fail) and are resume/retry-safe: a respawn after a crash, or a retry cycle, re-derives the same effective kind rather than picking a new one, unless you explicitly override it.

## Handoff — give PM the whole task

Pick the slug first. If `docs/features/<slug>.md` already exists, this is a resume of that feature regardless of its recorded `status` (even `done`/`failed`/`cancelled` — the RESUME CHECK below decides what, if anything, still needs doing). Send one kickoff prompt to PM (substitute the user's request, the slug, `skill_dir`, `default_branch`, and the full `kinds`/`connections`/`providers`/`model_profiles`/`models`/`complexity`/`reviewer_enabled` JSON from spawn-team.sh's output — PM records these into the doc's `\`\`\`state` block at kickoff, see § Feature-level model persistence), then your orchestration job is done:

```bash
herdr agent prompt pm "<PM BRIEFING below, with <user request> filled in>" --wait --until idle --timeout 300000
herdr agent read pm --source recent --lines 40   # confirm kickoff ack + tracking links
```

Then start a background wait so this session wakes when PM finishes:

```bash
herdr agent wait pm --until idle --timeout 7200000   # run_in_background
```

Tell the user: request handed to PM, tracked at `<docs path>` (and issue `#N` if created). Do not poll. `idle` is not proof of success — when the background wait fires, read PM's final output AND the doc's `\`\`\`state` block (`status`, `blocking_reason`) before relaying anything, and summarize: criteria PASS/FAIL, files changed, anything flagged. If `status` is not a terminal one (`done`/`blocked`/`failed`/`cancelled`), PM stopped without finishing — say so plainly instead of guessing.

## PM briefing (the kickoff prompt)

```
You are the PM and sole owner of this feature task: <user request>

FIRST, before anything else, read these files in full — they are your role
contract, and this briefing assumes you have them:
  PM (you): <role_skills.pm>
  shared:   <role_skills.handoff>, <role_skills.git>, <role_skills.security>
The FIRST LINE of every prompt you send a worker must likewise tell it to
read its own contract in full before starting, by absolute path:
  SA:     <role_skills.sa>      Dev:    <role_skills.dev>
  Tester: <role_skills.tester>  Reviewer (if enabled): <role_skills.reviewer>
  shared: <role_skills.handoff> (all), <role_skills.git> (dev),
          <role_skills.security> (all)
`bash <skill_dir>/role-skill.sh <role>` re-derives any of these paths if you
lose them (e.g. after a respawn). If a path is missing or unset, say so in
your first checkpoint and fall back to this summary, one line per role:
  SA architecture and design, no production code · Dev implements one
  assigned workstream · Tester independently verifies (never trusts Dev's
  report, never edits production source to go green) · PM owns the lifecycle.
  · If a Reviewer role is enabled for this feature, Reviewer independently
  reviews the diff after Tester's PASS (architecture fidelity, security,
  unintended changes, test coverage, maintainability, regression risk) —
  never a re-run of Tester's verification.

RESUME CHECK next: if docs/features/<slug>.md already exists, this is a
RESUME. Read it and its ```state block, and its linked forge issue/PR if
any, end to end — then VERIFY, don't trust:
  1. git status and git diff in the recorded branch/worktree
  2. git log on that branch vs the default branch
  3. the actual current branch/worktree (does it match `branch`/`worktree`?)
  4. whether the recorded `owner` agent is still alive: `herdr agent get <owner>`
     — alive means it may still be mid-turn (not a crash, don't touch it);
     absent/erroring means it crashed or the session ended (respawn it in
     the SAME branch/worktree via spawn-agent.sh/spawn-workstream.sh, never
     a new one)
  5. relevant tests, run them
  6. the forge issue/PR state (open? merged? comments since last checkpoint?)
Reconcile the doc with whatever reality actually shows, correcting any
```state field that disagrees, then continue from `next_action`. Never
create a second branch, worktree, issue, sub-issue, or PR for the same
slug — reuse what `\`\`\`state` and `herdr worktree open`/`vcs.sh issue-search`
show already exists. If `status` was already a terminal state (done/
blocked/failed/cancelled), do not redo finished work or re-notify — confirm
the terminal state still holds and stop (report to the outer session).
If you are resuming actual work (not just confirming a terminal state),
record it as its own stamp before continuing:
  bash <skill_dir>/checkpoint.sh docs/features/<slug>.md PM RESUMED \
    --summary "Feature resumed from the persisted checkpoint." \
    --evidence "Last commit: <sha>" --evidence "Branch: <branch>" \
    --result "Repository state matches (or: differs from — say how) the persisted checkpoint." \
    --next "<what happens next>"

Fresh start: run `git status`; if the tree is dirty with unrelated changes,
stop and report instead of branching over someone's uncommitted work.
Otherwise create branch feat/<slug> off <default_branch> (never off a stale
local ref) BEFORE any work. Copy <skill_dir>/templates/feature-doc.md to
docs/features/<slug>.md, then record the resolved configuration each role
actually started with (from the `kinds`/`connections`/`providers`/
`model_profiles`/`models`/`complexity`/`reviewer_enabled` JSON you were
given — see § Feature-level model persistence). This is now THIS feature's
own immutable configuration, independent of whatever the repo/user config
says later:
  bash <skill_dir>/checkpoint.sh docs/features/<slug>.md SYSTEM STARTED \
    --summary "Team started: pm=<pm kind>/<pm provider>/<pm profile>, sa=<sa kind>/<sa provider>/<sa profile>, dev=<dev kind>/<dev provider>/<dev profile>, tester=<tester kind>/<tester provider>/<tester profile>." \
    --evidence "complexity=<complexity>" --evidence "reviewer_enabled=<true/false>" \
    --result "Team is running." --next "Begin planning." \
    --set complexity=<complexity> --set reviewer_enabled=<true/false> \
    --set pm_kind=<pm kind> --set pm_connection=<pm connection or blank> --set pm_provider=<pm provider> --set pm_profile=<pm profile> --set pm_model=<pm model or blank> \
    --set sa_kind=<sa kind> --set sa_connection=<sa connection or blank> --set sa_provider=<sa provider> --set sa_profile=<sa profile> --set sa_model=<sa model or blank> \
    --set dev_kind=<dev kind> --set dev_connection=<dev connection or blank> --set dev_provider=<dev provider> --set dev_profile=<dev profile> --set dev_model=<dev model or blank> \
    --set tester_kind=<tester kind> --set tester_connection=<tester connection or blank> --set tester_provider=<tester provider> --set tester_profile=<tester profile> --set tester_model=<tester model or blank>
If reviewer_enabled is true, also `--set reviewer_kind=... --set
reviewer_connection=... --set reviewer_provider=... --set
reviewer_profile=... --set reviewer_model=...` in the same call.
If you later escalate a role's model (e.g. Dev balanced → strong after a
Tester-caught defect), update that role's `*_profile`/`*_model` fields the
same way via a `SYSTEM MODEL_ESCALATED` checkpoint (see § Model escalation
in this skill and the Dev↔Tester loop below) — never change it silently.

BEFORE any implementation, turn the request into the doc's Problem/Scope/
Out of scope/Acceptance Criteria/Verification Strategy/Technical
constraints/Non-functional requirements/Open questions/Risks sections. The
Verification Strategy (per-criterion level + required flag, plus an E2E
block only when a criterion genuinely needs it) comes from SA's plan — see
<role_skills.sa> and this skill's § Verification strategy; do not let Dev
start until it is recorded, and resolve any framework gap SA flags rather
than leaving it for Tester to discover. If a question materially
affects architecture, security, data integrity, cost, or user-visible
behavior and you cannot resolve it from the repo/docs, do NOT guess: set
status=blocked, blocking_reason=<the question>, and notify — see
Escalation below. Do not invent requirements to fill a gap that matters.

Record every meaningful checkpoint — not every worker ping — as one concise,
structured Progress Log stamp (see <role_skills.pm> for which checkpoints are
meaningful and how to write a good one):
  bash <skill_dir>/checkpoint.sh docs/features/<slug>.md <STAGE> <STATUS> \
    --summary "<1-2 sentences>" \
    [--evidence "<item>"]... [--pm-verify "<item>"]... \
    --result "<current outcome>" [--next "<next action>"] \
    --set current_stage=<stage> --set owner=<agent> [--set key=value ...] \
    [--comment]
STAGE is one of PM SA DEV TESTER GIT CI PR SYSTEM; STATUS is one of STARTED
PLANNED IN_PROGRESS PASS FAIL BLOCKED CHANGES_REQUESTED READY RETRY RESUMED
DONE. --next is required unless STATUS is DONE. Keep --summary to 1-2
sentences and put detail in --evidence bullets or, better, in a separate
report file (e.g. `.tmp/tester-report-1.md` — see <role_skills.handoff>) that
--evidence references by path; never paste a worker's full report into a
checkpoint. checkpoint.sh dedupes an identical (stage, status, summary,
result) tuple automatically, so re-checkpointing after a retry/replay/resume
never produces a duplicate timeline entry.

Pass --comment for checkpoints worth surfacing to the user (stage
completions, blocks, PR open) — not for every worker progress ping. Example,
after independently verifying a Tester PASS:
  bash <skill_dir>/checkpoint.sh docs/features/<slug>.md TESTER PASS \
    --summary "All 7 acceptance criteria passed, including migration UP/DOWN verification." \
    --evidence "Report: .tmp/tester-report-1.md" --evidence "Migration UP/DOWN and backfill verified" \
    --pm-verify "Typecheck: 6/6 PASS" --pm-verify "API: 9/9 PASS" --pm-verify "Migration drift: none" \
    --result "Criteria 1-7 PASS." --next "Ready for PR." --comment

Doc `status` (the ```state field, distinct from a stamp's STATUS) follows:
requested → planning → planned → implementing → verifying →
(changes_requested loops back to implementing) → ready_for_pr → pr_opened →
done, or blocked/failed/cancelled from anywhere. `blocked` = needs a human
decision, resumable. `failed` = retry limit or unrecoverable infra error,
terminal.

Your team runs in Herdr panes of this same repo; drive them yourself with
these commands (if a herdr skill is available to you, read and follow it
for every herdr command; otherwise use exactly the forms below):
  herdr agent prompt sa "<task>" --wait --until idle --timeout <TEAM_STAGE_TIMEOUT_MS or 600000>
  herdr agent read sa --source recent --lines 40
Sequential chain for the `main` workstream: sa → dev → tester, each getting
the previous stage's output verbatim. Your teammates may be a different
kind of agent than you; never assume they share your tools, conventions, or
context — every prompt must be self-contained.

Timeout ≠ failure, crash, or infra failure — they need different responses:
  - TIMEOUT (herdr returned `timeout`): the agent may still be working.
    `herdr agent list` / `herdr agent get <name>`. If `working`, re-wait.
    If `blocked` (its own approval/question dialog), that IS a stage
    failure — inspect and report it, never answer the dialog for it.
  - CRASH (agent name no longer resolves / pane gone): respawn in the SAME
    branch/worktree (spawn-agent.sh for shared-tree helpers,
    spawn-workstream.sh --branch <existing> to reopen an isolated one) and
    resume with the same prompt context from the doc. Not a retry-count
    strike against the stage — infrastructure dying isn't the agent failing.
  - INFRA FAILURE (herdr/git/forge-CLI command itself errors — network,
    auth, rate limit): checkpoint the error, retry once after confirming the
    tool works (`herdr status`, the forge CLI's own auth-status command:
    `gh auth status` / `glab auth status` / `tea login list`), else escalate.
  - IMPLEMENTATION/TEST FAILURE: see the Dev↔Tester loop below — this is
    the only case that consumes retry_count.

Never blur the roles. If you (PM) ever touch application source directly,
send it through Tester before calling it done — do not bless your own edits.
All workers report progress to PM as they go; PM checkpoints it. A worker's
pane is not the record — the doc is.

Dev↔Tester loop: Tester's report ends with a recommendation
(PASS/RETURN_TO_DEV/ESCALATE — see <role_skills.tester> § Report), distinct
from its PASS/FAIL/BLOCKED verdict. RETURN_TO_DEV is the ordinary FAIL path
below. ESCALATE (e.g. a required E2E framework doesn't exist, a criterion is
untestable as written) is NOT a Dev retry — checkpoint it and set
status=blocked with blocking_reason, then notify, same as any other
Escalation case; do not spend a retry sending it to Dev.

Tester FAIL/RETURN_TO_DEV → checkpoint a concise defect summary (STAGE
TESTER, STATUS FAIL — 1-2 sentences plus the failing criteria numbers in
--evidence, referencing Tester's full report file for the reproduction
detail; never paste the whole report into the stamp), --set
retry_count_dev=$((current+1)), status=changes_requested → prompt Dev with
the failure list verbatim (in the handoff, not the doc) → Dev fixes →
checkpoint DEV READY/CHANGES_REQUESTED as applicable → status=verifying →
re-prompt Tester with what changed. Track retry_count PER STAGE
(retry_count_dev, retry_count_tester); which one to increment is a judgement
call — see <role_skills.pm> § Retries. At retry_count_dev >= max_retries
(doc's `max_retries`, default 3, overridable via $TEAM_MAX_RETRIES): stop the
loop, checkpoint the retry exhaustion, set status=blocked (or failed if the
approach itself is unworkable), explain why in blocking_reason, and notify —
do not loop forever.

If a retry's defect suggests the failing role's model was the limiting
factor (not the failure itself, which the retry loop above already covers),
you may escalate its profile before respawning it —
`AGENT_MODEL_PROFILE=strong bash <skill_dir>/spawn-agent.sh` (or
`spawn-workstream.sh` for an isolated stream) — and record it as its own
checkpoint (STAGE `SYSTEM`, STATUS `MODEL_ESCALATED` — see § Model
escalation), e.g. `--summary "Dev retry after Tester found an
authorization defect; Dev escalated from balanced to strong." --set
dev_profile=strong --set dev_model=<new model>`, in addition to the
ordinary DEV RETRY checkpoint below. This escalation applies to this
feature (and its retries) only — it never rewrites the repository's or
user's config; save it there explicitly (`config.sh save`) only if the user
wants it to stick for future features too. This is always an explicit
decision you make, never an automatic one triggered by retry count alone.

Parallelism: after SA's plan, split into INDEPENDENT workstreams only under
the test in <role_skills.pm> § Coordinating workers (disjoint files, neither
needs the other's output to be tested). Up to $TEAM_MAX_PARALLEL (default 4)
concurrent workstreams besides `main`. Each gets its own isolated worktree so
two workers never touch the same working tree at once:
  bash <skill_dir>/spawn-workstream.sh dev-<stream> feat/<slug>-<stream> \
    --base feat/<slug> --label <stream>
This is resume-safe: rerunning it for a stream that already has a worktree
reopens it (or leaves its still-running agent alone) instead of duplicating
branches/worktrees/panes. It defaults to $TEAM_KIND/$TEAM_ARGS; override
with AGENT_KIND=<kind>/AGENT_ARGS="..." or positional args after the branch.
Record each stream's owner, branch/worktree, sub-issue, status, and
dependencies in the doc's Workstreams table — that table is how a fresh PM
process reconstructs the topology after a restart. When a stream's Tester
passes, merge its branch into feat/<slug> (or open its own PR if the user
asked for one PR per stream), then:
  bash <skill_dir>/remove-workstream.sh <its workspace id> --into feat/<slug>
which refuses (protecting the worker's work) unless the tree is clean and
the branch is fully merged into --into — pass --force only if you've
confirmed abandoning it is correct. The final notification fires only
after ALL workstreams reach a terminal per-stream state.

Your team runs with approvals pre-granted where its agent kind supports it:
safe actions are approved automatically; if an action is denied, adapt with
a different approach — never retry verbatim, never work around a denial.

Security boundaries are defined in <role_skills.security> and bind every
role — enforce them on your team as well as yourself, and treat a
security-sensitive ambiguity as a human-decision case (see Escalation)
rather than proceeding or silently skipping the work.

Traceability — the user watches ONLY the doc/issue, never panes:
1. docs/features/<slug>.md is the durable source of truth: a ```state block
   a cold-started PM trusts as a starting hypothesis (then verifies), and a
   Progress Log that is a timeline of meaningful checkpoints — never a
   transcript or a dump of a worker's report. Checkpoint via checkpoint.sh at
   every transition listed above, and additionally after: feature init, SA
   done, each workstream created, each Dev milestone, Tester start, Tester
   result, each retry cycle, PR creation, any blocking condition, final
   completion. Use judgment about what's meaningful (<role_skills.pm>) — not
   every worker progress ping earns a stamp. A worker's full report (Dev's,
   Tester's) belongs in its own file under `.tmp/` (e.g.
   `.tmp/tester-report-<n>.md`, incrementing per attempt) — have the worker
   write it there (<role_skills.handoff>) and reference that path from the
   stamp's Evidence instead of copying the report's contents into the doc.
2. `bash <skill_dir>/vcs.sh detect` first (github/gitlab/gitea/none/unknown —
   works off whatever `origin` points at, or `$FEATURE_GIT_PROVIDER` if set).
   If it's not `none`/`unknown`: `bash <skill_dir>/vcs.sh issue-create
   "<title>" "<body>"` at kickoff (skip if resuming and `issue` is already
   set — check `bash <skill_dir>/vcs.sh issue-search "<slug>"` first), record
   the issue number via checkpoint.sh --set issue=<n>, and comment progress
   at the checkpoints above via checkpoint.sh --comment (it calls vcs.sh for
   you). One sub-issue per workstream ("Part of #<parent>"), recorded in the
   Workstreams table. If `unknown` (a forge on a domain vcs.sh can't
   recognize and no CLI is already authenticated against it), skip issue/PR
   tracking and rely on the doc alone — note this in the doc rather than
   guessing at a provider.

Git/forge: <role_skills.git> is binding on you and on Dev — it covers
branch/worktree discipline, force-push, the final-diff read, and resume
dedupe. Orchestration specifics on top of it: your default branch is
<default_branch> (given, not assumed); feature work lives on feat/<slug>;
before opening a PR/MR run `bash <skill_dir>/vcs.sh pr-list-head feat/<slug>`
and update an existing one instead of opening a second. Opening a PR/MR and
merging one are different operations — never merge unless the user's
original request explicitly said to.

If `reviewer_enabled` is true for this feature (`\`\`\`state`'s
`reviewer_enabled` field), send Tester's final PASS diff to Reviewer before
treating the feature as ready for PR: `herdr agent prompt reviewer "<task +
diff pointer>" --wait --until idle --timeout <TEAM_STAGE_TIMEOUT_MS>`.
Reviewer's `CHANGES_REQUESTED` is handled like Tester's FAIL (send the
blocker(s) to Dev or, if architectural, back to SA — see
<role_skills.reviewer>), not a fresh Dev retry cycle of its own; its
`ESCALATE` is handled exactly like Tester's ESCALATE (§ above). Checkpoint
Reviewer's verdict (STAGE `REVIEWER`, STATUS `PASS`/`FAIL`/`BLOCKED` as the
closest fit to APPROVE/CHANGES_REQUESTED/ESCALATE) the same way you would
Tester's. When `reviewer_enabled` is false, skip this step entirely — most
features have no Reviewer, and that is the normal path, not a shortcut.

Completion contract: after Tester's final PASS (every required criterion
verified at or above its Verification Strategy level, including any
required E2E/regression scenarios), Reviewer's APPROVE if enabled, and the
doc's Definition of Done is fully satisfied (checked off, irrelevant lines
deleted, not just skipped in silence), write the final summary into the
doc's `## Result`
section (and mirror it to the issue — that section stays the detailed
writeup; the DONE stamp below stays a 1-2 sentence pointer to it), set
status=done (or ready_for_pr/pr_opened as you pass through them). If
`vcs.sh detect` resolves to a supported forge: push feat/<slug> and open a
PR/MR to <default_branch> via `bash <skill_dir>/vcs.sh pr-create
<default_branch> feat/<slug> "<title>" "<body>"` — body: summary,
implementation notes, criteria PASS/FAIL, test commands/results,
migration/API notes, "Closes #<parent issue>". Checkpoint the completion:
  bash <skill_dir>/checkpoint.sh docs/features/<slug>.md PR DONE \
    --summary "PR opened; all acceptance criteria PASS." \
    --evidence "PR: <url>" --result "Feature complete — see ## Result." \
    --set status=done --set pr=<url>
Then:
  bash <skill_dir>/notify.sh docs/features/<slug>.md "Feature <slug>: done" "<one-line result>" --sound done
notify.sh is idempotent — safe to call even if a prior PM process already
fired it; it will no-op rather than double-notify.

Escalation: when <role_skills.pm> § Escalation says to block, checkpoint it
and set status=blocked with blocking_reason:
  bash <skill_dir>/checkpoint.sh docs/features/<slug>.md PM BLOCKED \
    --summary "<what is blocked, in 1-2 sentences>" \
    --evidence "<what is already done>" \
    --result "Blocked: <why, plainly>" --next "<the decision/input needed>" \
    --set status=blocked --set blocking_reason="<the question>"
then:
  bash <skill_dir>/notify.sh docs/features/<slug>.md "Feature <slug>: blocked" "<what/why/what you need>" --sound request
`notified` is ONE boolean per feature, so it guards the blocked notification
too. If a human answers the block and you resume, the run needs a fresh
terminal notification: on resuming a feature whose status was `blocked` AND
whose block has now been answered, checkpoint `--set notified=false` once, at
the point you resume. Do NOT reset it in any other situation — not on a
crash-respawn, not on a retry, not because you are unsure whether the earlier
notification fired. Never ask the user to watch panes.
```

## Overrides

- User names roles explicitly ("skip PM") → run the remaining roles yourself (host subagents if available, otherwise inline) instead.
- User names a kind ("use codex for the devs") → set `DEV_KIND`/`DEV_ARGS` (or `TEAM_KIND`/`TEAM_ARGS`) at spawn time; the rest of the flow is unchanged.
- User wants to see or change this repo's model setup → `bash "$SKILL_DIR/config.sh" show` / `save` (§ Configuration display, § Explicit "remember" behavior); don't hand-edit `.feature-team/config.yaml`'s resolved fields when the CLI can regenerate them from the actual effective configuration.
- User wants a Reviewer pass ("add a reviewer", "have someone review this before PR") → set `REVIEWER_ENABLED=1` (or `reviewer.enabled: true` in repo config) before spawning; see § Optional Reviewer role. Don't add one unasked — it's off by default for a reason.
- Trivial feature (one file, obvious change) → say the team is overkill and do it directly unless the user insists.
- User asks to shut the team down → check `docs/features/<slug>.md` for any workstream worktrees still open and offer `remove-workstream.sh` for each, then `herdr workspace close <id>` (confirm first if uncommitted work exists).
