---
name: feature-team
description: "Fire-and-forget dev team (PM → SA → Dev → Tester) as Herdr agents of any supported kind (claude, codex, gemini, cursor, …). The PM owns the task end-to-end through an explicit state machine, checkpointing every transition to docs/features/<slug>.md and a mirrored tracking issue (GitHub, GitLab, or Gitea — whichever forge `origin` points at); the user walks away and gets one notification when the feature reaches done/blocked/failed. Use for new feature requests, e.g. '/feature-team add bulk export'. Requires running inside Herdr."
---

# Feature Team (Herdr) — fire-and-forget

The user submits a request and walks away. **PM owns the task**: PM drives SA → Dev → Tester through an explicit state machine, checkpoints every transition to the tracking doc and issue, and fires exactly one terminal notification. You (this session) only: set up the team, hand the request to PM, tell the user where it's tracked, and relay one summary when PM finishes. Never ask the user to watch panes or approve prompts.

The roles are agent-kind agnostic — the team can be all `claude`, all `codex`, or mixed. Kind and CLI flags are configuration (see Setup); nothing in this skill assumes a particular agent CLI beyond the defaults for `claude`.

Scratch files stay in the repo: never write to `/tmp` or other system temp dirs. Prefer recording notes/findings/status as a comment on the tracking doc or forge issue instead of a scratch file — that's also what the user actually watches. If an agent (PM or worker) genuinely needs disposable scratch space (not something worth tracking), use `.tmp/` at the repo root (create it if missing; it should not be committed — add it to `.gitignore` if not already ignored).

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
| `vcs.sh` | forge-agnostic issue/PR operations — detects GitHub/GitLab/Gitea from `origin` and drives `gh`/`glab`/`tea` accordingly |
| `role-skill.sh` | print the absolute path of a role contract (`pm`/`sa`/`dev`/`tester`/`handoff`/`git`/`security`), or `--json` for all |
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

## Setup — one command

Run the spawn script (next to this skill; `$SKILL_DIR` below is its directory). It captures this session's provider/config env, creates a `feature: <slug>` workspace, lays out four panes, starts the starters (`pm`/`sa`/`dev`/`tester`), and waits for them to boot:

```bash
bash "$SKILL_DIR/spawn-team.sh" <slug>
```

The final JSON line gives `workspace`, each agent's `pane` id, each agent's `kind`, `default_branch` (detected from the repo, not assumed to be `main`), `skill_dir` (use that absolute path in the PM briefing), and `role_skills` (absolute path per role contract — substitute these into the briefing too). Agent-name collisions (a rerun while starters are alive) fail fast with herdr's error — rename or close the old workspace first.

Configuration (env vars, all optional):

| var | effect |
| --- | --- |
| `TEAM_KIND` | agent kind for every role (default `claude`); any kind `herdr agent` lists |
| `PM_KIND` `SA_KIND` `DEV_KIND` `TESTER_KIND` | per-role kind override |
| `TEAM_ARGS` | args passed verbatim to every agent CLI after `--` |
| `PM_ARGS` `SA_ARGS` `DEV_ARGS` `TESTER_ARGS` | per-role args override |
| `PM_MODEL` `SA_MODEL` (default `opus`), `DEV_MODEL` `TESTER_MODEL` (default `sonnet`) | model for kind `claude`'s default args only |
| `TEAM_ENV_PREFIXES` `TEAM_ENV_KEYS` `TEAM_ENV_DENY` | which env vars reach the team's panes (see `agent-env.sh`) |
| `FEATURE_GIT_PROVIDER` | force the forge (`github`/`gitlab`/`gitea`) instead of auto-detecting it from `origin`'s hostname — needed for a self-hosted instance on a domain that doesn't contain "github"/"gitlab"/"gitea" (see `vcs.sh`) |
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

Dev↔Tester loop: Tester FAIL → checkpoint the failure list, --set
retry_count_dev=$((current+1)), status=changes_requested → prompt Dev with
the failure list verbatim → Dev fixes → status=verifying → re-prompt Tester
with what changed. Track retry_count PER STAGE (retry_count_dev,
retry_count_tester); which one to increment is a judgement call — see
<role_skills.pm> § Retries. At retry_count_dev >= max_retries (doc's
`max_retries`, default 3, overridable via $TEAM_MAX_RETRIES): stop the
loop, set status=blocked (or failed if the approach itself is unworkable),
explain why in blocking_reason, and notify — do not loop forever.

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
1. docs/features/<slug>.md is the durable source of truth; the ```state
   block is what a cold-started PM trusts as a starting hypothesis (then
   verifies). Update it via checkpoint.sh at every transition listed above,
   and additionally after: feature init, SA done, each workstream created,
   each Dev milestone, Tester start, Tester result, each retry cycle, PR
   creation, any blocking condition, final completion.
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

Completion contract: after Tester's final PASS and the doc's Definition of
Done is fully satisfied (checked off, irrelevant lines deleted, not just
skipped in silence), write the final summary into the doc's `## Result`
section (and mirror it to the issue), set
status=done (or ready_for_pr/pr_opened as you pass through them). If
`vcs.sh detect` resolves to a supported forge: push feat/<slug> and open a
PR/MR to <default_branch> via `bash <skill_dir>/vcs.sh pr-create
<default_branch> feat/<slug> "<title>" "<body>"` — body: summary,
implementation notes, criteria PASS/FAIL, test commands/results,
migration/API notes, "Closes #<parent issue>". Then:
  bash <skill_dir>/notify.sh docs/features/<slug>.md "Feature <slug>: done" "<one-line result>" --sound done
notify.sh is idempotent — safe to call even if a prior PM process already
fired it; it will no-op rather than double-notify.

Escalation: when <role_skills.pm> § Escalation says to block, set
status=blocked with blocking_reason via checkpoint.sh, then:
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
