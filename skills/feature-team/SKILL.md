---
name: feature-team
description: "Fire-and-forget dev team (PM → SA → Dev → Tester) as Herdr agents. The PM owns the task end-to-end; the user walks away and tracks progress via docs/ and GitHub issues, getting one message when done. Use for new feature requests, e.g. '/feature-team add bulk export'. Requires running inside Herdr."
---

# Feature Team (Herdr) — fire-and-forget

The user submits a request and walks away. **PM owns the task**: PM drives SA → Dev → Tester, writes all tracking, and fires the completion notification. You (this session) only: set up the team, hand the request to PM, tell the user where it's tracked, and relay one summary when PM finishes. Never ask the user to watch panes or approve prompts.

## Preflight

```bash
test "${HERDR_ENV:-}" = 1 || fallback
```

If not inside Herdr, run PM → SA → Dev → Tester yourself with native subagents (Plan for SA, general-purpose for the rest), tracking in the same docs/issue format, and report inline.

## Setup — one command

Run the spawn script (next to this skill). It captures this session's Claude settings (config dir like `~/.claudez`, provider, model mappings — never `CLAUDE_CODE_*`), creates a `feature: <slug>` workspace, lays out four panes, starts the starters (`pm`/`sa` on opus, `dev`/`tester` on sonnet, all `--permission-mode auto`), and waits for them to boot:

```bash
bash .claude/skills/feature-team/spawn-team.sh <slug>
```

The final JSON line gives `workspace` (`$W`) and each agent's pane id. Model overrides: `PM_MODEL/SA_MODEL/DEV_MODEL/TESTER_MODEL` env vars. Agent-name collisions (a rerun while starters are alive) fail fast with herdr's error — rename or close the old workspace first.

## Handoff — give PM the whole task

Pick the slug first. If `docs/features/<slug>.md` already exists with status in-progress or blocked, this is a resume of that feature (the PM briefing's RESUME CHECK handles it — the doc/issue carry all state; old panes/agents are gone). Send one kickoff prompt to PM (substitute the user's request and the slug), then your orchestration job is done:

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
in-progress or blocked, this is a RESUME, not a fresh start. Read the doc
and its linked issue end to end, then verify the claimed state against
reality (git status/diff, run the test suite, open the named files) and
correct the doc where reality disagrees. Comment your resume plan on the
issue, create a sub-issue for each remaining chunk ("Part of #<parent>"),
and continue from the doc's "Resume state" section. The old agents are
gone — respawn workers as needed via spawn-agent.sh.

Your team runs in Herdr panes of this same repo; drive them yourself (you
have the herdr skill — read and follow it for every herdr command):
  herdr agent prompt sa "<task>" --wait --until idle --timeout 600000
  herdr agent read sa --source recent --lines 40
(sa → dev → tester, in that order — each gets the previous output verbatim.
Dev implements in the working tree; Tester runs check/lint/test and each
acceptance criterion, reporting PASS/FAIL. Never parallelize.)

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
  bash .claude/skills/feature-team/spawn-agent.sh dev-<stream> <one of your pane ids> [model]
The script splits a pane off yours, forwards your inherited env, starts
claude with --permission-mode auto, waits until idle, and prints
{name,pane,model} (default model sonnet). If the name is taken, rerun with
-2 appended. Then prompt it like the starters. Record each stream's owner
in the doc/issue workstream map. A feature with no independent streams
spawns nobody. The final notification fires only after ALL streams are
done or blocked.

You run under auto permission mode: safe actions are approved automatically;
if an action is denied, adapt with a different approach — never retry
verbatim, never work around a denial.

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
   comments. Do NOT push branches or open PRs unless the user's request said so.

Completion contract: after Tester reports, write the final summary to doc +
issue, set status done (or blocked with the reason), then notify:
  herdr notification show "Feature <slug>: done" --body "<one-line result>" --sound done
If a stage fails twice or requirements conflict with reality, stop the team,
mark blocked in doc/issue with the reason, and notify with --sound request.
```

## Overrides

- User names roles explicitly ("skip PM") → run the remaining roles yourself via native subagents instead.
- Trivial feature (one file, obvious change) → say the team is overkill and do it directly unless the user insists.
- User asks to shut the team down → `herdr workspace close <id>` (confirm first if uncommitted work exists).
