---
name: feature-team
description: "Fire-and-forget dev team (PM → SA → Dev → Tester) as Herdr agents of any supported kind (claude, codex, gemini, cursor, …). The PM owns the task end-to-end; the user walks away and tracks progress via docs/ and GitHub issues, getting one message when done. Use for new feature requests, e.g. '/feature-team add bulk export'. Requires running inside Herdr."
---

# Feature Team (Herdr) — fire-and-forget

The user submits a request and walks away. **PM owns the task**: PM drives SA → Dev → Tester, writes all tracking, and fires the completion notification. You (this session) only: set up the team, hand the request to PM, tell the user where it's tracked, and relay one summary when PM finishes. Never ask the user to watch panes or approve prompts.

The roles are agent-kind agnostic — the team can be all `claude`, all `codex`, or mixed. Kind and CLI flags are configuration (see Setup); nothing in this skill assumes a particular agent CLI beyond the defaults for `claude`.

## Preflight

```bash
test "${HERDR_ENV:-}" = 1 || fallback
```

If not inside Herdr, run PM → SA → Dev → Tester yourself — via your host's own subagent mechanism if it has one (e.g. Claude Code: Plan for SA, general-purpose for the rest), otherwise sequentially in this session — tracking in the same docs/issue format, and report inline.

## Setup — one command

Run the spawn script (next to this skill; `$SKILL_DIR` below is its directory). It captures this session's provider/config env, creates a `feature: <slug>` workspace, lays out four panes, starts the starters (`pm`/`sa`/`dev`/`tester`), and waits for them to boot:

```bash
bash "$SKILL_DIR/spawn-team.sh" <slug>
```

The final JSON line gives `workspace`, each agent's `pane` id, each agent's `kind`, and `skill_dir` (use that absolute path in the PM briefing). Agent-name collisions (a rerun while starters are alive) fail fast with herdr's error — rename or close the old workspace first.

Configuration (env vars, all optional):

| var | effect |
| --- | --- |
| `TEAM_KIND` | agent kind for every role (default `claude`); any kind `herdr agent` lists |
| `PM_KIND` `SA_KIND` `DEV_KIND` `TESTER_KIND` | per-role kind override |
| `TEAM_ARGS` | args passed verbatim to every agent CLI after `--` |
| `PM_ARGS` `SA_ARGS` `DEV_ARGS` `TESTER_ARGS` | per-role args override |
| `PM_MODEL` `SA_MODEL` (default `opus`), `DEV_MODEL` `TESTER_MODEL` (default `sonnet`) | model for kind `claude`'s default args only |
| `TEAM_ENV_PREFIXES` `TEAM_ENV_KEYS` `TEAM_ENV_DENY` | which env vars reach the team's panes (see `agent-env.sh`) |

With no `*_ARGS`, kind `claude` starts as `--model <role model> --permission-mode auto`. **Any other kind starts bare** — the script does not guess another CLI's flags, so pass the model and auto-approve flags yourself, e.g.:

```bash
TEAM_KIND=codex TEAM_ARGS="--model gpt-5-codex --full-auto" bash "$SKILL_DIR/spawn-team.sh" bulk-export
```

If the user names a kind without its flags, ask for the flags once (or check that CLI's `--help`) rather than starting agents that stop on every approval.

## Handoff — give PM the whole task

Pick the slug first. If `docs/features/<slug>.md` already exists with status in-progress or blocked, this is a resume of that feature (the PM briefing's RESUME CHECK handles it — the doc/issue carry all state; old panes/agents are gone). Send one kickoff prompt to PM (substitute the user's request, the slug, and `skill_dir`), then your orchestration job is done:

```bash
herdr agent prompt pm "<PM BRIEFING below, with <user request> filled in>" --wait --until idle --timeout 300000
herdr agent read pm --source recent --lines 40   # confirm kickoff ack + tracking links
```

Then start a background wait so this session wakes when PM finishes:

```bash
herdr agent wait pm --until idle --timeout 7200000   # run_in_background
```

Tell the user: request handed to PM, tracked at `<docs path>` (and issue `#N` if created). Do not poll. When the background wait fires, read PM's final output plus the doc/issue and relay one summary: criteria PASS/FAIL, files changed, anything flagged.

## PM briefing (the kickoff prompt)

```
You are the PM and sole owner of this feature task: <user request>

RESUME CHECK first: if docs/features/<slug>.md already exists with status
in-progress or blocked, this is a RESUME, not a fresh start. Check out the
existing feat/<slug> branch (it holds the partial work). Read the doc
and its linked issue end to end, then verify the claimed state against
reality (git status/diff, run the test suite, open the named files) and
correct the doc where reality disagrees. Comment your resume plan on the
issue, create a sub-issue for each remaining chunk ("Part of #<parent>"),
and continue from the doc's "Resume state" section. The old agents are
gone — respawn workers as needed via spawn-agent.sh.

Fresh start: create branch feat/<slug> off the current default branch
BEFORE any work — all code AND the doc land on it.

Your team runs in Herdr panes of this same repo; drive them yourself with
these commands (if a herdr skill is available to you, read and follow it
for every herdr command; otherwise use exactly the forms below):
  herdr agent prompt sa "<task>" --wait --until idle --timeout 600000
  herdr agent read sa --source recent --lines 40
(sa → dev → tester, in that order — each gets the previous output verbatim.
Dev implements in the working tree; Tester runs check/lint/test and each
acceptance criterion, reporting PASS/FAIL. Never parallelize.)
Your teammates may be a different kind of agent than you; never assume
they share your tools, conventions, or context — every prompt must be
self-contained.

Roles: SA plans (files, approach, risks, max 20 lines, no code).
Dev implements (match code style, validate at trust boundaries, report files changed).
Tester verifies (PASS/FAIL per criterion, failures verbatim).
All workers: report progress to PM as you go (what is done, what remains) —
PM checkpoints it into doc/issue. Your pane is not a record; the doc is.
Timeout ≠ failure: check `herdr agent list`, re-wait if `working`.

Parallelism: after SA's plan, split the work into INDEPENDENT workstreams.
The starter sa/dev/tester are yours forever — never replace or spawn a
second pm. Sequential work just uses the starters. For each extra parallel
workstream, spawn its own workers (sa-<stream> only if it needs separate
design; dev-<stream> always; tester-<stream> at verify time):
  bash <skill_dir>/spawn-agent.sh dev-<stream> <one of your pane ids>
The script splits a pane off yours, forwards your inherited env, starts the
agent, waits until idle, and prints {name,pane,kind,args}. It defaults to
the same kind and CLI args as the team (TEAM_KIND/TEAM_ARGS, already in
your environment); override per worker with AGENT_KIND=<kind> or by passing
the agent's args after the pane id. If the name is taken, rerun with -2
appended. Then prompt it like the starters. Record each stream's owner in
the doc/issue workstream map. A feature with no independent streams spawns
nobody. The final notification fires only after ALL streams are done or
blocked.

Your team runs with approvals pre-granted where its agent kind supports it:
safe actions are approved automatically; if an action is denied, adapt with
a different approach — never retry verbatim, never work around a denial.
If a worker sits blocked on its own approval dialog, treat that as a stage
failure and report it — do not answer the dialog for it.

Traceability — the user watches ONLY these, never panes. Every action,
status change, and progress report must land here, because the doc/issue
must be enough to resume the task cold after any outage:
1. docs/features/<slug>.md — create at kickoff with sections: Status
   (requested → in-progress → done/blocked), Criteria (numbered, PASS/FAIL),
   Workstreams (owner agent, sub-issue link, status), Stage log (one line
   per stage/progress report), Resume state (what is DONE, what REMAINS,
   NEXT action — kept current at all times). Update it at every stage
   transition AND whenever a worker reports progress. If the session dies,
   this section is the next PM's starting point.
2. If `git remote -v` shows a github.com remote: `gh issue create` at kickoff
   with the criteria, link it in the doc, and keep it mirroring the doc —
   PM comments current progress/status there at every checkpoint, and one
   sub-issue per workstream ("Part of #<parent>") with worker progress as
   comments.

Completion contract: after Tester reports, write the final summary to doc +
issue, set status done (or blocked with the reason). If github remote and
all criteria pass: `git push -u origin feat/<slug>` and open a PR to the
default branch — body: summary, criteria PASS/FAIL, "Closes #<parent
issue>" (the issue auto-closes on merge). Then notify:
  herdr notification show "Feature <slug>: done" --body "<one-line result>" --sound done
If blocked: no PR — mark blocked in doc/issue with the reason and notify
with --sound request. If a stage fails twice or requirements conflict with
reality, stop the team and do the same.
```

## Overrides

- User names roles explicitly ("skip PM") → run the remaining roles yourself (host subagents if available, otherwise inline) instead.
- User names a kind ("use codex for the devs") → set `DEV_KIND`/`DEV_ARGS` (or `TEAM_KIND`/`TEAM_ARGS`) at spawn time; the rest of the flow is unchanged.
- Trivial feature (one file, obvious change) → say the team is overkill and do it directly unless the user insists.
- User asks to shut the team down → `herdr workspace close <id>` (confirm first if uncommitted work exists).
