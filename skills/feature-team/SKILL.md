---
name: feature-team
description: "Fire-and-forget dev team (PM → SA → Dev → Tester) as Herdr agents of any supported kind (claude, codex, gemini, cursor, …). The PM owns the task end-to-end through an explicit state machine, checkpointing every transition to docs/features/<slug>.md and a mirrored GitHub issue; the user walks away and gets one notification when the feature reaches done/blocked/failed. Use for new feature requests, e.g. '/feature-team add bulk export'. Requires running inside Herdr."
---

# Feature Team (Herdr) — fire-and-forget

The user submits a request and walks away. **PM owns the task**: PM drives SA → Dev → Tester through an explicit state machine, checkpoints every transition to the tracking doc and issue, and fires exactly one terminal notification. You (this session) only: set up the team, hand the request to PM, tell the user where it's tracked, and relay one summary when PM finishes. Never ask the user to watch panes or approve prompts.

The roles are agent-kind agnostic — the team can be all `claude`, all `codex`, or mixed. Kind and CLI flags are configuration (see Setup); nothing in this skill assumes a particular agent CLI beyond the defaults for `claude`.

Scratch files stay in the repo: never write to `/tmp` or other system temp dirs. Prefer recording notes/findings/status as a comment on the tracking doc or GitHub issue instead of a scratch file — that's also what the user actually watches. If an agent (PM or worker) genuinely needs disposable scratch space (not something worth tracking), use `.tmp/` at the repo root (create it if missing; it should not be committed — add it to `.gitignore` if not already ignored).

**Design principle this skill follows**: anything that can be enforced deterministically (state transitions, notification idempotency, git isolation, doc formatting) is a script, not a paragraph of instructions an LLM has to remember to follow the same way every time. The scripts below are load-bearing; the PM briefing only covers judgment calls a script can't make.

## Scripts in this directory

| script | purpose |
| --- | --- |
| `spawn-team.sh` | one-shot: create workspace + panes, start pm/sa/dev/tester |
| `spawn-agent.sh` | spawn a helper in a pane that **shares** the caller's working tree — sequential or read-only work only |
| `spawn-workstream.sh` | spawn a worker for an **independent, concurrent** code-writing workstream in its own Git worktree — resume-safe (reopens instead of duplicating) |
| `remove-workstream.sh` | tear down a workstream's worktree; refuses if it has uncommitted or unmerged work unless `--force` |
| `checkpoint.sh` | append a Stage log line + update `\`\`\`state` fields in the tracking doc, in one call |
| `notify.sh` | fire the terminal notification exactly once per feature (checks/sets `notified` in the doc) |
| `templates/feature-doc.md` | the tracking-doc skeleton (state machine, acceptance criteria, DoD, resume state) |

All of them accept `-h`/malformed-arg errors verbatim from `herdr`/`git` — no retry logic hides a real failure.

## Preflight

```bash
test "${HERDR_ENV:-}" = 1 || fallback
```

If not inside Herdr, run PM → SA → Dev → Tester yourself — via your host's own subagent mechanism if it has one (e.g. Claude Code: Plan for SA, general-purpose for the rest), otherwise sequentially in this session — tracking in the same docs/issue format (copy `templates/feature-doc.md`), and report inline. `spawn-workstream.sh`/`remove-workstream.sh` require Herdr's `worktree` command group; without it, parallel workstreams fall back to sequential work in one working tree.

## Setup — one command

Run the spawn script (next to this skill; `$SKILL_DIR` below is its directory). It captures this session's provider/config env, creates a `feature: <slug>` workspace, lays out four panes, starts the starters (`pm`/`sa`/`dev`/`tester`), and waits for them to boot:

```bash
bash "$SKILL_DIR/spawn-team.sh" <slug>
```

The final JSON line gives `workspace`, each agent's `pane` id, each agent's `kind`, `default_branch` (detected from the repo, not assumed to be `main`), and `skill_dir` (use that absolute path in the PM briefing). Agent-name collisions (a rerun while starters are alive) fail fast with herdr's error — rename or close the old workspace first.

Configuration (env vars, all optional):

| var | effect |
| --- | --- |
| `TEAM_KIND` | agent kind for every role (default `claude`); any kind `herdr agent` lists |
| `PM_KIND` `SA_KIND` `DEV_KIND` `TESTER_KIND` | per-role kind override |
| `TEAM_ARGS` | args passed verbatim to every agent CLI after `--` |
| `PM_ARGS` `SA_ARGS` `DEV_ARGS` `TESTER_ARGS` | per-role args override |
| `PM_MODEL` `SA_MODEL` (default `opus`), `DEV_MODEL` `TESTER_MODEL` (default `sonnet`) | model for kind `claude`'s default args only |
| `TEAM_ENV_PREFIXES` `TEAM_ENV_KEYS` `TEAM_ENV_DENY` | which env vars reach the team's panes (see `agent-env.sh`) |
| `TEAM_MAX_RETRIES` | default `3` — max Dev↔Tester fix/re-verify cycles per workstream before PM must mark `blocked`/`failed` |
| `TEAM_MAX_PARALLEL` | default `4` — max concurrent workstreams (beyond the always-sequential `main`) |
| `TEAM_STAGE_TIMEOUT_MS` | default `600000` — the timeout PM should pass to `herdr agent prompt --wait` for SA/Dev/Tester turns |

With no `*_ARGS`, kind `claude` starts as `--model <role model> --permission-mode auto`. **Any other kind starts bare** — the script does not guess another CLI's flags, so pass the model and auto-approve flags yourself, e.g.:

```bash
TEAM_KIND=codex TEAM_ARGS="--model gpt-5-codex --full-auto" bash "$SKILL_DIR/spawn-team.sh" bulk-export
```

If the user names a kind without its flags, ask for the flags once (or check that CLI's `--help`) rather than starting agents that stop on every approval.

## Handoff — give PM the whole task

Pick the slug first. If `docs/features/<slug>.md` already exists, this is a resume of that feature regardless of its recorded `status` (even `done`/`failed`/`cancelled` — the RESUME CHECK below decides what, if anything, still needs doing). Send one kickoff prompt to PM (substitute the user's request, the slug, `skill_dir`, and `default_branch`), then your orchestration job is done:

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

RESUME CHECK first: if docs/features/<slug>.md already exists, this is a
RESUME. Read it and its ```state block, and its linked GitHub issue/PR if
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
  6. the GitHub issue/PR state (open? merged? comments since last checkpoint?)
Reconcile the doc with whatever reality actually shows, correcting any
```state field that disagrees, then continue from `next_action`. Never
create a second branch, worktree, issue, sub-issue, or PR for the same
slug — reuse what `\`\`\`state` and `herdr worktree open`/`gh issue list`
show already exists. If `status` was already a terminal state (done/
blocked/failed/cancelled), do not redo finished work or re-notify — confirm
the terminal state still holds and stop (report to the outer session).

Fresh start: run `git status`; if the tree is dirty with unrelated changes,
stop and report instead of branching over someone's uncommitted work.
Otherwise create branch feat/<slug> off <default_branch> (never off a stale
local ref) BEFORE any work. Copy <skill_dir>/templates/feature-doc.md to
docs/features/<slug>.md.

BEFORE any implementation, turn the request into the doc's Problem/Scope/
Out of scope/Acceptance Criteria/Technical constraints/Non-functional
requirements/Open questions/Risks sections. If a question materially
affects architecture, security, data integrity, cost, or user-visible
behavior and you cannot resolve it from the repo/docs, do NOT guess: set
status=blocked, blocking_reason=<the question>, and notify — see
Escalation below. Do not invent requirements to fill a gap that matters.

Record every transition with:
  bash <skill_dir>/checkpoint.sh docs/features/<slug>.md "<what happened>" \
    --set current_stage=<stage> --set owner=<agent> [--set key=value ...] [--comment]
Pass --comment for checkpoints worth surfacing to the user (stage
completions, blocks, PR open) — not for every worker progress ping. States:
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
  - INFRA FAILURE (herdr/gh/git command itself errors — network, auth,
    rate limit): checkpoint the error, retry once after confirming the
    tool works (`herdr status`, `gh auth status`), else escalate.
  - IMPLEMENTATION/TEST FAILURE: see the Dev↔Tester loop below — this is
    the only case that consumes retry_count.

Roles (never blur these):
  SA: architecture, affected files/modules, API/data-model implications,
    risks, migration considerations, testing strategy. Max ~20 lines, no
    code. SA does not modify production source.
  Dev: implements per SA's plan, adds unit/integration tests where
    appropriate, matches existing code style, validates at trust
    boundaries, reports files changed + how to run them.
  Tester: independent verification — inspect the ACTUAL git diff and repo
    state yourself, don't just trust Dev's report. Check acceptance
    criteria, tests, lint/typecheck/build, API contract, auth(n/z),
    migrations, integration/E2E, Docker where relevant — whatever of these
    actually applies to this change (see the doc's Definition of Done; skip
    the rest, don't pad). Tester does not modify production source to make
    tests pass. On failure, report EACH failing criterion as: criterion,
    expected, actual, repro steps, command/test, relevant error/log,
    severity — verbatim into the doc, not paraphrased away.
  PM: everything above plus orchestration, checkpointing, git/issue/PR
    coordination, the blocked/done call, and notification. If you (PM) ever
    touch application source directly, send it through Tester again before
    calling it done — do not silently bless your own edits.
All workers report progress to PM as they go; PM checkpoints it. A worker's
pane is not the record — the doc is.

Dev↔Tester loop: Tester FAIL → checkpoint the failure list, --set
retry_count_dev=$((current+1)), status=changes_requested → prompt Dev with
the failure list verbatim → Dev fixes → status=verifying → re-prompt Tester
with what changed. Track retry_count PER STAGE (retry_count_dev,
retry_count_tester) — a Tester false-positive that Dev disputes is a
different situation than three straight real bugs; use judgement about
whose count to increment. At retry_count_dev >= max_retries (doc's
`max_retries`, default 3, overridable via $TEAM_MAX_RETRIES): stop the
loop, set status=blocked (or failed if the approach itself is unworkable),
explain why in blocking_reason, and notify — do not loop forever.

Parallelism: after SA's plan, split the work into INDEPENDENT workstreams
only if they touch disjoint files/modules and don't need each other's
output to be tested — never split work that shares files. Up to
$TEAM_MAX_PARALLEL (default 4) concurrent workstreams besides `main`. For
each one, spawn its own isolated worktree so two workers never touch the
same working tree at once:
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

Security boundaries: never run destructive/production operations (terraform
apply, production DB migrations, `docker system prune`, `rm -rf` outside
this repo's working trees, changing repo/CI permissions) unless the user's
request explicitly authorized exactly that. Do not forward or echo secrets
(.env contents, tokens, SSH/cloud credentials) into the doc, issue, PR, or
worker prompts beyond what each worker's own environment already has
through normal env forwarding — workers should never need you to hand them
a credential in plaintext. Treat any of the above as a human-decision case
(see Escalation) rather than proceeding or silently skipping it.

Traceability — the user watches ONLY the doc/issue, never panes:
1. docs/features/<slug>.md is the durable source of truth; the ```state
   block is what a cold-started PM trusts as a starting hypothesis (then
   verifies). Update it via checkpoint.sh at every transition listed above,
   and additionally after: feature init, SA done, each workstream created,
   each Dev milestone, Tester start, Tester result, each retry cycle, PR
   creation, any blocking condition, final completion.
2. If `git remote -v` shows a github.com remote: `gh issue create` at
   kickoff (skip if resuming and `issue` is already set) with the criteria,
   record the issue number via checkpoint.sh --set issue=<n>, and comment
   progress at the checkpoints above via checkpoint.sh --comment. One
   sub-issue per workstream ("Part of #<parent>"), recorded in the
   Workstreams table.

Git/GitHub rules: detect the default branch, never assumed to be `main`
(you were given it as <default_branch>; re-verify with
`git symbolic-ref refs/remotes/origin/HEAD` if anything looks off). Never
commit to the default branch. Never force-push. Never discard changes you
didn't author. Before opening a PR, diff feat/<slug> against <default_branch>
and re-read it yourself — this is part of Definition of Done, not
optional. Before opening a PR, check `gh pr list --head feat/<slug>` so
resume never opens a duplicate; if one exists, update it instead. Report CI
failures verbatim rather than guessing at a fix. On a real merge conflict,
stop and report it (a human or a targeted Dev turn resolves it — don't
force through). Opening a PR and merging one are different operations:
never merge unless the user's original request explicitly said to.

Completion contract: after Tester's final PASS and the doc's Definition of
Done is fully satisfied (checked off, irrelevant lines deleted, not just
skipped in silence), write the final summary to doc + issue, set
status=done (or ready_for_pr/pr_opened as you pass through them). If a
GitHub remote exists: push feat/<slug> and open a PR to <default_branch> —
body: summary, implementation notes, criteria PASS/FAIL, test
commands/results, migration/API notes, "Closes #<parent issue>". Then:
  bash <skill_dir>/notify.sh docs/features/<slug>.md "Feature <slug>: done" "<one-line result>" --sound done
notify.sh is idempotent — safe to call even if a prior PM process already
fired it; it will no-op rather than double-notify.

Escalation (status=blocked, then notify with --sound request): requirements
materially conflict; architecture needs a product decision; a destructive/
production operation would be required; credentials/permissions are
missing; a security-sensitive ambiguity exists; a test reveals unclear
expected behavior you can't resolve from the repo; retry_count hit
max_retries. The notification body must state: what is blocked, why, what
decision/input is needed, what's already done, what happens once resolved.
Never ask the user to watch panes.
```

## Overrides

- User names roles explicitly ("skip PM") → run the remaining roles yourself (host subagents if available, otherwise inline) instead.
- User names a kind ("use codex for the devs") → set `DEV_KIND`/`DEV_ARGS` (or `TEAM_KIND`/`TEAM_ARGS`) at spawn time; the rest of the flow is unchanged.
- Trivial feature (one file, obvious change) → say the team is overkill and do it directly unless the user insists.
- User asks to shut the team down → check `docs/features/<slug>.md` for any workstream worktrees still open and offer `remove-workstream.sh` for each, then `herdr workspace close <id>` (confirm first if uncommitted work exists).
