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

## Setup — one workspace, four panes

Capture the current Claude settings so spawned agents run identically (config dir like `~/.claudez`, provider, model mappings). `agent start` has no `--env`; env rides on `workspace create` / `pane split`:

```bash
TEAM_ENV=()
for k in CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
         ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
         ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL; do
  v=$(printenv "$k") && [ -n "$v" ] && TEAM_ENV+=(--env "$k=$v")
done
```

Never propagate `CLAUDE_CODE_*` / `CLAUDE_PID` / session IDs — they point at this session, not the new agents.

```bash
herdr workspace create --label "feature: <short slug>" --focus "${TEAM_ENV[@]}"
```

Read `.result.workspace.workspace_id` (`$W`), `.result.root_pane.pane_id` (`$P1` — PM). Split the rest, capturing each `.result.pane.pane_id`:

```bash
herdr pane split "$P1" --direction right "${TEAM_ENV[@]}"   # P2 — SA
herdr pane split "$P1" --direction down "${TEAM_ENV[@]}"    # P3 — Dev
herdr pane split "$P2" --direction down "${TEAM_ENV[@]}"    # P4 — Tester
```

Model split: PM/SA reason on high, Dev/Tester execute on low. `--model opus/sonnet` resolves through the inherited `ANTHROPIC_DEFAULT_*_MODEL` mappings. Agents run with `--permission-mode auto` — the same auto-approval mode as this session, no bypass: safe actions proceed, risky ones get classified and can be denied (agents adapt or mark the task blocked instead of stalling).

```bash
herdr agent start pm     --kind claude --pane "$P1" -- --model opus --permission-mode auto
herdr agent start sa     --kind claude --pane "$P2" -- --model opus --permission-mode auto
herdr agent start dev    --kind claude --pane "$P3" -- --model sonnet --permission-mode auto
herdr agent start tester --kind claude --pane "$P4" -- --model sonnet --permission-mode auto
```

Wait for all four: `herdr agent wait <name> --until idle --timeout 120000`.

## Handoff — give PM the whole task

Send one kickoff prompt to PM (substitute the user's request), then your orchestration job is done:

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

Your team runs in Herdr panes of this same repo; drive them yourself:
  herdr agent prompt sa "<task>" --wait --until idle --timeout 600000
  herdr agent read sa --source recent --lines 40
(sa → dev → tester, in that order — each gets the previous output verbatim.
Dev implements in the working tree; Tester runs check/lint/test and each
acceptance criterion, reporting PASS/FAIL. Never parallelize.)

Roles: SA plans (files, approach, risks, max 20 lines, no code).
Dev implements (match code style, validate at trust boundaries, report files changed).
Tester verifies (PASS/FAIL per criterion, failures verbatim).
Timeout ≠ failure: check `herdr agent list`, re-wait if `working`.

Parallelism: after SA's plan, split the work into INDEPENDENT workstreams.
The starter sa/dev/tester are yours forever — never replace or spawn a
second pm. Sequential work just uses the starters. For each extra parallel
workstream, spawn its own workers (sa-<stream> only if it needs separate
design; dev-<stream> always; tester-<stream> at verify time) using your own
inherited env:
  TEAM_ENV=(); for k in CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
    ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL; do \
    v=$(printenv "$k") && [ -n "$v" ] && TEAM_ENV+=(--env "$k=$v"); done
  herdr pane split <any of your panes> --direction down "${TEAM_ENV[@]}"
  herdr agent start dev-<stream> --kind claude --pane <new pane id> -- \
    --model sonnet --permission-mode auto
Then `herdr agent wait dev-<stream> --until idle --timeout 120000` and prompt
it like the starters. Names: global, [a-z][a-z0-9_-], max 32 chars — if
taken, append -2. Record each stream's owner in the doc/issue workstream
map. A feature with no independent streams spawns nobody. The final
notification fires only after ALL streams are done or blocked.

You run under auto permission mode: safe actions are approved automatically;
if an action is denied, adapt with a different approach — never retry
verbatim, never work around a denial.

Track everything — the user watches ONLY these, never panes:
1. docs/features/<slug>.md — create at kickoff: status line (requested →
   in-progress → done/blocked), numbered acceptance criteria with
   PASS/FAIL, files changed, short stage log (PM/SA/Dev/Tester, one line each).
   Update it at every stage transition and at completion.
2. If `git remote -v` shows a github.com remote: `gh issue create` at kickoff
   with the criteria, link it in the doc, and `gh issue comment` per stage.
   Do NOT push branches or open PRs unless the user's request said so.

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
