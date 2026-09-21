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
| `role-skill.sh` | print the absolute path of a role contract (`pm`/`sa`/`dev`/`tester`/`handoff`/`git`/`security`), or `--json` for all |
| `model-registry.sh` | maps `<provider, model profile>` → a concrete model id; sourced by `agent-env.sh` (see § Model selection) — the ONLY place provider model ids live |
| `test-provider-inheritance.sh` | regression test for provider-inheritance precedence/detection (see Provider inheritance) AND model-profile/registry resolution (see Model selection) — run it after touching `agent-env.sh`/`spawn-team.sh`'s kind or model resolution, or `model-registry.sh` |
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

Effective precedence for each role, highest first:

```
role-specific override (PM_KIND/SA_KIND/DEV_KIND/TESTER_KIND)
    > team-level override (TEAM_KIND)
    > calling agent/provider (detected, or $FEATURE_TEAM_CALLER_KIND)
    > fail — no provider is ever silently chosen
```

Examples (caller = pi):

| config | result |
| --- | --- |
| none | PM=pi SA=pi DEV=pi TESTER=pi |
| `DEV_KIND=claude` | PM=pi SA=pi **DEV=claude** TESTER=pi |
| `TEAM_KIND=codex` | PM=codex SA=codex DEV=codex TESTER=codex |
| `TEAM_KIND=codex TESTER_KIND=gemini` | PM=codex SA=codex DEV=codex **TESTER=gemini** |

Explicit configuration always wins — setting some roles explicitly does not normalize the rest back to the caller's provider; unset roles still inherit the caller.

### How the caller's kind is determined

`detect_caller_kind` in `agent-env.sh`, in order:
1. `$FEATURE_TEAM_CALLER_KIND` — set this yourself if you know your own kind and want to guarantee correct detection (recommended for any agent kind not covered by #2, e.g. Pi): `export FEATURE_TEAM_CALLER_KIND=pi`.
2. Well-known runtime signals checked automatically: `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT` → `claude`; `CODEX_SANDBOX*` → `codex`; `CURSOR_TRACE_ID` → `cursor`; a generic `AI_AGENT` slug some terminal integrations set (e.g. Warp) → parsed for a known provider prefix.
3. If nothing matches: undetected. The spawn scripts then fail with `Unable to determine calling agent provider. Set TEAM_KIND explicitly, or export FEATURE_TEAM_CALLER_KIND=<kind>.` — **never a silent claude fallback.**

Provider identity is a runtime concern, never inferred from the repo (no scanning for `.claude/`, no guessing from language/framework/installed binaries).

## Model selection

Three independent concepts, never conflated:

```
Role      PM / SA / DEV / TESTER — a fixed contract (feature-pm/sa/dev/tester); never changes with the model
Provider  the agent kind's own vendor/CLI (claude, codex→openai, gemini, deepseek, ...)
Model     a provider-specific identifier ("opus", "gpt-5.1", "deepseek-reasoner", ...)
```

Between Role and Model sits one more concept, **Model Profile** — a semantic
preference, not a model name:

```
strong     for planning/reasoning-heavy work
balanced   for well-constrained implementation work
fast       for cheap, narrowly-scoped work
```

`strong`/`balanced`/`fast` are per-provider *selection preferences*, never a
cross-provider equivalence claim — `strong` on Claude and `strong` on
DeepSeek are each "the configured stronger model for that provider," not
"the same tier of model." Role skills (`feature-pm`/`sa`/`dev`/`tester`)
never mention a provider or a model name — see § Why PM/SA default stronger.

### Precedence

For each role, highest first:

```
explicit <ROLE>_MODEL           e.g. DEV_MODEL=gpt-5.1-mini
    > <ROLE>_MODEL_PROFILE       e.g. DEV_MODEL_PROFILE=strong
    > TEAM_MODEL_PROFILE         team-wide default profile
    > role's built-in default profile (PM/SA=strong, DEV/TESTER=balanced)
```

The resolved profile is then looked up in **model-registry.sh**, the one
file that maps `<provider, profile> → model id`, for the role's OWN
resolved kind (§ Provider inheritance above) — never another kind's model.
`model-registry.sh` itself checks, in order: `<KIND>_<PROFILE>_MODEL` (e.g.
`CODEX_STRONG_MODEL`), then `<VENDOR-FAMILY>_<PROFILE>_MODEL` (e.g.
`OPENAI_STRONG_MODEL`, which also covers kind `codex`), then a small set of
seed defaults it ships with, then empty. **Empty means "no opinion" — the
provider's own CLI default applies.** A missing profile entry for a
provider never falls back to another provider's model; that would be a
silent provider switch, which this skill never does (same principle as the
kind-detection fail path above).

### Why PM/SA default to a stronger profile

PM owns requirements interpretation, scope, acceptance criteria,
orchestration, retries, and lifecycle decisions; SA owns architecture,
system impact, API/data design, security tradeoffs, and migration design.
Errors at either stage propagate into every downstream worker — a wrong
acceptance criterion or a flawed design gets implemented and "tested"
against the wrong target. Dev and Tester's tasks are narrower and more
constrained (by the acceptance criteria + SA's design + existing code + a
test plan), so a smaller/cheaper model is *often* sufficient — but not
always; escalate per-feature when it isn't (below).

### Examples

Caller = Pi, provider = OpenAI, no explicit overrides:

```
PM      → OpenAI's configured "strong" model
SA      → OpenAI's configured "strong" model
DEV     → OpenAI's configured "balanced" model
TESTER  → OpenAI's configured "balanced" model
```

Mixed providers (explicit configuration only — never automatic):

```
SA_KIND=claude   SA_MODEL_PROFILE=strong \
DEV_KIND=deepseek DEV_MODEL_PROFILE=balanced \
bash "$SKILL_DIR/spawn-team.sh" bulk-export
# → PM=<caller>, SA=claude strong, DEV=deepseek balanced, TESTER=<caller> balanced
```

Cost/quality tradeoff, orchestration unchanged either way:

```
DEV_MODEL_PROFILE=fast TESTER_MODEL_PROFILE=fast     # cheaper
DEV_MODEL_PROFILE=strong TESTER_MODEL_PROFILE=strong # highest quality
```

### Per-feature escalation

PM may escalate a role's profile for a specific feature or retry — this is
always an explicit configuration/decision, never an automatic judgment call
based on vague difficulty heuristics:

```
Simple feature:   PM=strong SA=strong DEV=balanced TESTER=fast
Complex feature:  PM=strong SA=strong DEV=strong   TESTER=balanced
High-risk:        PM=strong SA=strong DEV=strong   TESTER=strong
```

To escalate mid-run (e.g. after a Tester-caught defect), set
`AGENT_MODEL_PROFILE=strong` (or `AGENT_MODEL=<explicit>`) before
respawning that worker via `spawn-agent.sh`/`spawn-workstream.sh`, record
the new `<role>_kind`/`<role>_model` in the doc's `\`\`\`state` block, and
checkpoint the change explicitly (STAGE `PM`, mentioning the escalation in
`--summary`) — see templates/feature-doc.md's `state` block and the Dev↔
Tester loop below. Never change a role's model silently.

### Retry and resume

`spawn-team.sh` exports the resolved `PM_MODEL`/`SA_MODEL`/`DEV_MODEL`/
`TESTER_MODEL` (and their `*_MODEL_PROFILE`s) into the team's own panes, the
same way it exports the resolved kinds — so a PM that later calls
`spawn-agent.sh`/`spawn-workstream.sh` for a crash-respawn or a retry
reuses the team's actual configuration instead of re-deriving (or losing)
it. A resumed feature keeps each role's persisted `*_kind`/`*_model` (§
Resume state in templates/feature-doc.md) unless the user changes it or PM
explicitly escalates it.

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
| `PM_KIND` `SA_KIND` `DEV_KIND` `TESTER_KIND` | per-role kind override |
| `TEAM_ARGS` | args passed verbatim to every agent CLI after `--` |
| `PM_ARGS` `SA_ARGS` `DEV_ARGS` `TESTER_ARGS` | per-role args override |
| `PM_MODEL` `SA_MODEL` `DEV_MODEL` `TESTER_MODEL` | explicit model id per role — wins over everything below (see § Model selection) |
| `PM_MODEL_PROFILE` `SA_MODEL_PROFILE` `DEV_MODEL_PROFILE` `TESTER_MODEL_PROFILE` | semantic profile (`strong`/`balanced`/`fast`) per role |
| `TEAM_MODEL_PROFILE` | semantic profile for every role without its own override (default when unset: PM/SA=`strong`, DEV/TESTER=`balanced`) |
| `<KIND>_<PROFILE>_MODEL` / `<VENDOR>_<PROFILE>_MODEL` | provider-scoped model config, e.g. `CLAUDE_STRONG_MODEL`, `OPENAI_BALANCED_MODEL`, `DEEPSEEK_FAST_MODEL` — see `model-registry.sh` |
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

Pick the slug first. If `docs/features/<slug>.md` already exists, this is a resume of that feature regardless of its recorded `status` (even `done`/`failed`/`cancelled` — the RESUME CHECK below decides what, if anything, still needs doing). Send one kickoff prompt to PM (substitute the user's request, the slug, `skill_dir`, `default_branch`, and the `kinds`/`models` JSON from spawn-team.sh's output — PM records these into the doc's `\`\`\`state` block at kickoff, see § Model selection), then your orchestration job is done:

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
  Tester: <role_skills.tester>
  shared: <role_skills.handoff> (all), <role_skills.git> (dev),
          <role_skills.security> (all)
`bash <skill_dir>/role-skill.sh <role>` re-derives any of these paths if you
lose them (e.g. after a respawn). If a path is missing or unset, say so in
your first checkpoint and fall back to this summary, one line per role:
  SA architecture and design, no production code · Dev implements one
  assigned workstream · Tester independently verifies (never trusts Dev's
  report, never edits production source to go green) · PM owns the lifecycle.

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
docs/features/<slug>.md, then record the resolved kind/model each role
actually started with (from the `kinds`/`models` JSON you were given):
  bash <skill_dir>/checkpoint.sh docs/features/<slug>.md SYSTEM STARTED \
    --summary "Team started: pm=<pm kind>/<pm model>, sa=<sa kind>/<sa model>, dev=<dev kind>/<dev model>, tester=<tester kind>/<tester model>." \
    --result "Team is running." --next "Begin planning." \
    --set pm_kind=<pm kind> --set pm_model=<pm model or blank> \
    --set sa_kind=<sa kind> --set sa_model=<sa model or blank> \
    --set dev_kind=<dev kind> --set dev_model=<dev model or blank> \
    --set tester_kind=<tester kind> --set tester_model=<tester model or blank>
If you later escalate a role's model (e.g. Dev balanced → strong after a
Tester-caught defect), update that role's `*_model` field the same way and
say so in the checkpoint's --summary (see § Model selection in this skill
and the Dev↔Tester loop below) — never change it silently.

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
`spawn-workstream.sh` for an isolated stream) — and record both the
escalation and the resulting model in the same RETRY checkpoint, e.g.
`--summary "Dev retry after Tester found an authorization defect; Dev
escalated from balanced to strong." --set dev_model=<new model>`. This is
always an explicit decision you make, never an automatic one triggered by
retry count alone.

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

Completion contract: after Tester's final PASS (every required criterion
verified at or above its Verification Strategy level, including any
required E2E/regression scenarios) and the doc's Definition of Done is fully
satisfied (checked off, irrelevant lines deleted, not just skipped in
silence), write the final summary into the doc's `## Result`
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
- Trivial feature (one file, obvious change) → say the team is overkill and do it directly unless the user insists.
- User asks to shut the team down → check `docs/features/<slug>.md` for any workstream worktrees still open and offer `remove-workstream.sh` for each, then `herdr workspace close <id>` (confirm first if uncommitted work exists).
