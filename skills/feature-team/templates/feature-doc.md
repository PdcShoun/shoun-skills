<!--
Template for docs/features/<slug>.md — the durable source of truth for one
feature-team run. Copy this file to that path at kickoff and fill in the
placeholders; do not restructure the sections or the ```state block below —
scripts (checkpoint.sh, notify.sh, spawn-workstream.sh) parse it verbatim.
-->
# Feature: <slug>

## Problem

<what the user asked for, in their words, plus the problem it solves>

## Scope

<what this feature covers>

## Out of scope

<what it explicitly does not cover>

## Acceptance Criteria

Each criterion carries a verification level (`static`/`unit`/`integration`/
`contract`/`e2e`/`manual`) and whether that level is `required` for PASS — SA
proposes both while planning, PM records them here, and Tester may confirm or
adjust the level during verification (never silently — see feature-tester).

1. <criterion> — PENDING [level: <level>, required: <yes/no>]
2. <criterion> — PENDING [level: <level>, required: <yes/no>]

## Verification Strategy

<SA fills this in at planning time (feature-sa's `## Verification strategy`
output); PM copies it here before Dev starts; Tester treats it as the
required minimum and may raise or lower a level with reasoning. Omit the E2E
block entirely when no criterion needs it — most features don't.>

Required levels for this feature: <subset of static/unit/integration/contract/e2e/manual>

E2E: <omit this whole block if no criterion above needs e2e>
- required: yes
- framework: <discovered from the repo — e.g. playwright/cypress/a repo-native runner; never assumed. If none exists and E2E is genuinely required, say so as an open question for PM instead of proposing to add one.>
- scenarios:
  - id: E2E-1
    name: <scenario name>
    setup: <seeded/controlled state this scenario starts from>
    expected: <the observable, deterministic outcome>

Regression areas: <existing behavior this change risks breaking, worth a
regression check even without a dedicated acceptance criterion>

## Technical constraints

<framework/library/versioning constraints, if any>

## Non-functional requirements

<perf, security, a11y, i18n — only what actually applies>

## Open questions

<unresolved questions that do NOT block starting work; resolve or drop before done>

## Risks

<what could go wrong, and how it will be noticed>

## Definition of Done

Check off only the lines that apply to this feature; delete the rest instead
of leaving them unchecked — an unchecked-but-irrelevant line reads as an open
gap on resume.

- [ ] All acceptance criteria PASS at (or above) their required verification level
- [ ] Tests added/updated and passing
- [ ] Lint / typecheck pass
- [ ] Production build passes
- [ ] DB migration present, and applies cleanly to a fresh database
- [ ] API contract/schema updated
- [ ] Required E2E/regression scenarios (per Verification Strategy) PASS, deterministically
- [ ] AuthN/AuthZ and other security-sensitive paths checked
- [ ] Docker build/run/healthcheck verified
- [ ] Final diff reviewed against the default branch
- [ ] This doc and the tracking issue are up to date
- [ ] PR/MR opened (if a supported forge remote is configured — GitHub, GitLab, or Gitea)

## Workstreams

| id | owner | branch/worktree | sub-issue | status | depends on |
| --- | --- | --- | --- | --- | --- |
| main | pm | (feature branch, no isolation needed for sequential work) | — | requested | — |

## Progress Log

<!--
Append-only, newest last, via `checkpoint.sh` — never hand-edit this section
and never paste a worker's full report into it. Each entry is one stamp:

  [<UTC timestamp>] <STAGE> → <STATUS>

  Summary:
  <1-2 sentences>

  Evidence:
  - <artifact, report path, or key fact — not full command output>

  PM verification:
  - <independent check PM ran, if any — omit this section if none applied>

  Result:
  <current outcome, stated explicitly>

  Next:
  <concrete next action — omit only when STATUS is DONE>

STAGE is one of: PM SA DEV TESTER REVIEWER GIT CI PR SYSTEM (REVIEWER only
when this feature/repo has the optional Reviewer role enabled)
STATUS is one of: STARTED PLANNED IN_PROGRESS PASS FAIL BLOCKED
CHANGES_REQUESTED READY RETRY RESUMED DONE (SYSTEM stamps also use
MODEL_CONFIGURED/MODEL_ESCALATED/MODEL_UNAVAILABLE — see feature-team/
SKILL.md § Progress Log for model-configuration events specifically)

Detailed evidence (full test output, stack traces, command transcripts)
belongs in a separate report file (e.g. .tmp/tester-report-1.md), referenced
here by path — not duplicated inline. A stamp for the same (stage, status,
summary, result) is not repeated on retry/replay/resume; checkpoint.sh
dedupes it automatically.

Example:

[2026-09-19 05:03 UTC] TESTER → PASS

Summary:
All 7 acceptance criteria passed, including migration UP/DOWN verification.

Evidence:
- Report: .tmp/tester-report-1.md
- Migration UP/DOWN and existing-user backfill verified
- 4/4 required E2E scenarios PASS (playwright)

PM verification:
- Typecheck: 6/6 PASS
- API: 9/9 PASS
- Migration drift: none

Result:
Criteria 1-7 PASS.

Next:
Ready for PR.
-->

## Result

<!--
Written once, at a terminal state (done/blocked/failed/cancelled). This is
what the user reads instead of the panes, and what a later reader sees first:
what was built, each acceptance criterion PASS/FAIL with its evidence, the
test/lint/build commands and results, migration/API notes, what was
deliberately NOT done, and the PR link. If the state is blocked/failed, say
what is blocked, why, and what decision unblocks it.
-->

## Resume state

A new PM process trusts this block only as a *starting hypothesis* — verify
it against `git status`/`git log`/the forge issue/PR before acting on it,
and correct any field that disagrees with reality.

```state
status: requested
current_stage: pm
owner: pm
branch:
worktree:
issue:
pr:
last_checkpoint:
last_known_commit:
retry_count_sa: 0
retry_count_dev: 0
retry_count_tester: 0
max_retries: 3
next_action:
blocking_reason:
notified: false
complexity: normal
reviewer_enabled: false
pm_kind:
pm_connection:
pm_provider:
pm_profile:
pm_model:
sa_kind:
sa_connection:
sa_provider:
sa_profile:
sa_model:
dev_kind:
dev_connection:
dev_provider:
dev_profile:
dev_model:
tester_kind:
tester_connection:
tester_provider:
tester_profile:
tester_model:
reviewer_kind:
reviewer_connection:
reviewer_provider:
reviewer_profile:
reviewer_model:
```

`*_kind`/`*_connection`/`*_provider`/`*_profile`/`*_model` record the
effective configuration each role actually started with (from
spawn-team.sh's JSON output — see feature-team/SKILL.md § Model selection
and § Feature-level model persistence). This block, once written at
kickoff, is this feature's own immutable model configuration: on resume, a
role keeps this same connection/provider/profile/model even if the
repository's or user's config has since changed, unless the user explicitly
changes it or PM explicitly escalates it (e.g. Dev balanced → strong after
a defect) — record any such change here AND as its own Progress Log stamp
(STAGE `SYSTEM`, e.g. `MODEL_ESCALATED`), never silently. `reviewer_*`
fields stay blank when `reviewer_enabled` is false.

### State values

`requested → planning → planned → implementing → verifying → (changes_requested loops back to implementing) → ready_for_pr → pr_opened → done`, or `blocked` / `failed` / `cancelled` from any state.

- **blocked**: needs a human decision (ambiguous/conflicting requirement, missing credential, destructive op, unclear expected behavior). Not a failure — resumable once answered.
- **failed**: retry limit exhausted or an unrecoverable infrastructure error. Terminal; a human must restart it as a new attempt.
- A stalled/timed-out agent is neither: re-check `herdr agent list`/`agent get` before touching status — see SKILL.md § Timeouts vs failure.
