---
name: feature-handoff
description: "Internal shared contract for the feature-team skill — the wire format for messages between PM and SA/Dev/Tester. Not a standalone workflow. Read it when you are writing a handoff to a worker, or writing a report back to PM, inside a feature-team run. Orchestration — who is prompted when, and how the message is delivered — belongs to feature-team, not here."
---

# Feature handoff contract

Two artifacts, one each direction:

- **Handoff** — PM → worker. "Here is what you must achieve and everything you need to achieve it."
- **Report** — worker → PM. "Here is what I actually did, what I proved, and what is left."

Both are plain markdown sent as the body of a prompt (or pasted into the tracking doc / issue). Nothing here says *how* the message is delivered — see feature-team for that.

## Why the format is fixed

Your counterpart may be a different agent kind (claude, codex, gemini, cursor, …) in a different pane and a different working tree, with none of your context, tools, or conventions. It may also be a *fresh process* that replaced a crashed one. So:

- **Every handoff and report must be self-contained.** Never write "as discussed", "per the previous turn", "see my earlier analysis", or point at a pane.
- **Durable and actionable only.** A handoff is not a transcript. Drop reasoning that does not change what the recipient does.
- **Do not paste the whole feature doc.** Reference it by path (`docs/features/<slug>.md`) and inline only the slice that is relevant to this stage.
- **Never inline secrets** — no `.env` contents, tokens, keys, connection strings. Workers get credentials through their own environment. See feature-security.
- **Name files by repo-relative path**, commands verbatim, and criteria by their number in the doc so both sides can point at the same thing.

## Handoff format (PM → worker)

Include a section only when it has real content; delete the rest rather than writing "N/A" on ten lines.

```markdown
# Handoff

## Feature
<slug> — docs/features/<slug>.md (read it for anything not inlined here)

## Workstream
<id from the doc's Workstreams table>

## Role
<sa | dev | tester> — read <abs path to your role skill> in full before starting

## Current state
<state from the doc's ```state block>

## Objective
<the one outcome this turn must produce>

## Requirements
<only the requirements this turn touches>

## Acceptance criteria
<by number, verbatim from the doc>

## Architecture
<the SA decisions that constrain this turn>

## Constraints
<conventions, versions, compatibility, non-functional requirements>

## Files / modules
<repo-relative paths in scope — and what is explicitly out of scope>

## Dependencies
<other workstreams, branches, or external things this depends on>

## Risks
<known risks to watch while working>

## Previous work
<what is already done, incl. prior attempts and why they failed>

## Remaining work
<what this turn must close out>

## Validation
<checks already run and their result, so they are not blindly repeated>

## Branch / worktree
<branch name and worktree path this turn must work in — never "the current one">

## Blockers
<open blockers, or "none">
```

On a retry (Tester FAIL → Dev), the failure list goes into **Previous work** *verbatim* — the exact criterion, expected, actual, repro command and output that Tester reported. Do not paraphrase a failure into a summary; the paraphrase is where the fix goes wrong.

## Report format (worker → PM)

```markdown
# Report

## Role / Workstream
<role> / <workstream id>

## Outcome
<complete | changes-needed | blocked | failed>

## What changed
<repo-relative files + one line each; or "none — no production source modified">

## Commands run
<command> → <pass/fail + the number that matters>

## Evidence
<the output, log excerpt, or diff hunk that backs the outcome above>

## Findings
<per acceptance criterion where applicable; see feature-tester for the PASS/FAIL shape>

## Remaining work
<what is deliberately not done, and why>

## Blockers
<what stopped you and what decision/input unblocks it, or "none">
```

`Outcome` is a claim, not a verdict. PM verifies it against the repository before checkpointing it (see feature-pm), and Tester verifies Dev's independently (see feature-tester). Write the report so that verification is *easy* — exact commands, exact paths, exact output — not so that it is unnecessary.

## Boundaries

- Reporting is not checkpointing. Workers report; **PM** writes the tracking doc and issue (see feature-team's `checkpoint.sh`). A worker must not edit the doc's ```state block.
- If your report would be longer than the change it describes, cut the narration, not the evidence.
