# shoun-skills

A collection of [Claude Code](https://claude.com/claude-code) Skills.

## What's here

The flagship skill is **`feature-team`** — a fire-and-forget dev team for delivering features autonomously. Give it a request (`/feature-team add bulk export`) and it drives the whole thing through an explicit pipeline while you walk away:

```
PM → SA → Dev → Tester Lead ─┬─ Test Worker (static/smoke)
                              ├─ Test Worker (unit/API)
                              ├─ Test Worker (integration)
                              └─ Test Worker (e2e)
                     → (optional) Reviewer
```

- **PM** owns the task end-to-end: scope, acceptance criteria, coordination, retries, done/blocked calls.
- **SA** designs within the existing codebase's conventions.
- **Dev** implements one assigned workstream in its own branch/worktree.
- **Tester Lead** builds a verification plan and parallelizes it across narrow-scoped **Test Workers**, then owns the final PASS/FAIL/BLOCKED verdict.
- **Reviewer** (optional, off by default) gives an independent second look after Tester's PASS.

It runs as Herdr agents, is agnostic to agent kind (`claude`, `codex`, `gemini`, `cursor`, `pi`, ...), and by default every role inherits whatever provider invoked it. Every state transition is checkpointed to `docs/features/<slug>.md` and mirrored to a tracking issue on whichever forge `origin` points at (GitHub, GitLab, or Gitea) — you get exactly one notification when the feature reaches `done`/`blocked`/`failed`.

The second skill, **`repo-setup`**, is a lightweight, interview-driven flow for setting up (or filling gaps in) a repo's CI/CD, infrastructure-as-code, and deployment configuration. It detects what already exists — CI config, Dockerfiles, IaC files, package manager, existing deploy configs — and asks about the rest rather than assuming a stack, then writes the actual pipeline/IaC/deploy files instead of just a design doc. Runs as a single agent; no Herdr required.

## Skills

### `feature/` — the feature-team family

| Skill | Role |
| --- | --- |
| [`feature-team`](skills/feature/feature-team/SKILL.md) | Entry point. Orchestrates the whole team as Herdr agents, handles setup, checkpointing, notifications. |
| [`feature-pm`](skills/feature/feature-pm/SKILL.md) | PM role contract — owns the feature lifecycle end-to-end. |
| [`feature-sa`](skills/feature/feature-sa/SKILL.md) | Solution Architect role contract — designs within the existing repo's conventions. |
| [`feature-dev`](skills/feature/feature-dev/SKILL.md) | Dev role contract — implements one assigned workstream. |
| [`feature-tester`](skills/feature/feature-tester/SKILL.md) | Tester Lead role contract — plans verification, spawns Test Workers, owns the verdict. |
| [`feature-test-worker`](skills/feature/feature-test-worker/SKILL.md) | Test Worker role contract — verifies one narrow scope assigned by the Tester Lead. |
| [`feature-reviewer`](skills/feature/feature-reviewer/SKILL.md) | Optional Reviewer role contract — independent review after Tester's PASS. |
| [`feature-handoff`](skills/feature/feature-handoff/SKILL.md) | Shared contract — the PM ↔ worker message format. |
| [`feature-git`](skills/feature/feature-git/SKILL.md) | Shared contract — safe Git behavior (branches, worktrees, no force-push, etc). |
| [`feature-security`](skills/feature/feature-security/SKILL.md) | Shared contract — secrets, production systems, and workspace-boundary rules. |

### `repo-setup/` — the repo setup family

| Skill | Role |
| --- | --- |
| [`repo-setup`](skills/repo-setup/SKILL.md) | Entry point. Detects existing CI/CD, infra, and deployment setup; interviews you about what's missing; writes the actual config files. Single-agent, no Herdr required. |

## Requirements

- Herdr (a terminal multiplexer for coding agents) installed and running (`HERDR_ENV=1`) — `feature-team` spawns and coordinates its roles as Herdr agents/panes.
- A `git` remote pointing at GitHub, GitLab, or Gitea if you want the tracking issue mirrored automatically (optional — the feature still runs and checkpoints to `docs/features/<slug>.md` without one).

## Usage

```
/feature-team <describe the feature you want built>
```

See [`skills/feature/feature-team/SKILL.md`](skills/feature/feature-team/SKILL.md) for full configuration: multi-provider setups, cost-aware model selection per role, testing-architecture tuning, and the repo/user config file formats.

Or, for CI/CD, infra, and deployment setup (no Herdr needed):

```
/repo-setup
```

See [`skills/repo-setup/SKILL.md`](skills/repo-setup/SKILL.md) for the full detect → interview → confirm → write flow.
