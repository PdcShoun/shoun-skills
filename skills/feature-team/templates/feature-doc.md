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

1. <criterion> — PENDING
2. <criterion> — PENDING

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

- [ ] All acceptance criteria PASS
- [ ] Tests added/updated and passing
- [ ] Lint / typecheck pass
- [ ] Production build passes
- [ ] DB migration present, and applies cleanly to a fresh database
- [ ] API contract/schema updated
- [ ] Frontend/backend integration verified end-to-end
- [ ] AuthN/AuthZ and other security-sensitive paths checked
- [ ] Docker build/run/healthcheck verified
- [ ] Final diff reviewed against the default branch
- [ ] This doc and the GitHub issue are up to date
- [ ] PR opened (if a GitHub remote exists)

## Workstreams

| id | owner | branch/worktree | sub-issue | status | depends on |
| --- | --- | --- | --- | --- | --- |
| main | pm | (feature branch, no isolation needed for sequential work) | — | requested | — |

## Stage log

<!-- append-only, newest last: "- <UTC timestamp> [stage] message" -->

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
it against `git status`/`git log`/the GitHub issue/PR before acting on it,
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
```

### State values

`requested → planning → planned → implementing → verifying → (changes_requested loops back to implementing) → ready_for_pr → pr_opened → done`, or `blocked` / `failed` / `cancelled` from any state.

- **blocked**: needs a human decision (ambiguous/conflicting requirement, missing credential, destructive op, unclear expected behavior). Not a failure — resumable once answered.
- **failed**: retry limit exhausted or an unrecoverable infrastructure error. Terminal; a human must restart it as a new attempt.
- A stalled/timed-out agent is neither: re-check `herdr agent list`/`agent get` before touching status — see SKILL.md § Timeouts vs failure.
