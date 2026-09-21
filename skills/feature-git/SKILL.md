---
name: feature-git
description: "Internal shared contract for the feature-team skill — safe Git behavior for any agent that touches a repository during a feature run (PM and Dev especially; Tester reads only). Not a standalone workflow. Branch/worktree creation and teardown are orchestrated by feature-team's scripts; this file is the rules those scripts and agents both obey."
---

# Feature Git contract

Rules for every agent that runs git inside a feature-team run. They exist because several agents share one repository, and because a run can be interrupted and resumed by a *different process* than the one that started it.

## Never

- **Never commit to the default branch.** Feature work lands on `feat/<slug>` (or a workstream branch off it) and reaches the default branch only through a PR.
- **Never force-push.** Not `--force`, not `--force-with-lease`, not `push +ref`. If a push is rejected, report it — a rejected push means someone else's work is there.
- **Never discard changes you did not author.** No `git checkout -- .`, `git restore` over a dirty tree, `git reset --hard`, `git clean -fd`, or `git stash drop` on work whose provenance you have not confirmed.
- **Never assume a branch name.** Not `main`, not `master`, not "the current branch". Detect it (below) or use the name you were handed.
- **Never rewrite published history** (`rebase`/`commit --amend`/`filter-branch` on a pushed branch).
- **Never share one working tree between two concurrently-writing agents.** See Isolation.

## Detect, don't assume

The default branch:

```bash
git symbolic-ref --quiet --short refs/remotes/origin/HEAD   # → origin/<default>
git remote show origin | sed -n 's/^ *HEAD branch: *//p'    # fallback
```

`feature-team`'s `agent-env.sh` has this as `detect_default_branch`, and `spawn-team.sh` reports the result as `default_branch` — use the value you were given, and re-derive it only if something looks wrong.

Where you actually are:

```bash
git rev-parse --show-toplevel     # which working tree am I in?
git branch --show-current         # which branch?
git status --porcelain            # is it clean?
```

Verify these match the `branch`/`worktree` you were assigned in your handoff **before** you write anything. If they disagree, stop and report — do not "fix" it by switching branches under work you cannot see.

## Before modifying anything

1. `git status --porcelain` — if the tree is dirty with changes that are not yours, stop and report. Do not branch over, commit, or stash someone's uncommitted work.
2. Confirm the branch is the one you were assigned.
3. `git log --oneline <default_branch>..HEAD` — know what is already committed on this branch before adding to it. On a resume, this is how you avoid redoing or duplicating a commit that already landed.

## Isolation for concurrent work

Two agents writing in one working tree corrupt each other's state — a half-written file from one becomes the other's "existing code".

- Sequential or read-only helpers may share a tree (`feature-team/spawn-agent.sh`).
- **Any second concurrently-writing agent gets its own Git worktree** (`feature-team/spawn-workstream.sh`, which is resume-safe: it reopens an existing worktree for a branch instead of creating a duplicate).
- Tear down only via `feature-team/remove-workstream.sh`, which refuses to remove a tree with uncommitted or unmerged commits unless forced. If it refuses, that refusal is information — investigate, do not add `--force` to get past it.
- The same rule applies to the Tester Lead's parallel Test Workers, via `feature-team/spawn-test-worker.sh`: a read-only or single-scope verification worker shares the parent's tree; a worker that must write test files a concurrently-running worker might also touch gets its own worktree (`--worktree`). Test Workers should not be writing production source at all — see feature-tester and feature-test-worker.

Only the agent that owns a worktree writes in it. If you find work in a tree you were not assigned, report it.

## Committing

- Commit only files you changed for this workstream. `git add <paths>`, not `git add -A`, when the tree has anything else in it.
- Messages describe the change, not the process ("add bulk export endpoint", not "dev agent turn 3").
- Commit before handing back, so the next stage and any resume see your work as durable history rather than as an uncommitted tree that a crash would lose.

## Before completion

- Re-read the final diff yourself: `git diff <default_branch>...feat/<slug>`. Reading it is part of the Definition of Done, not an optional flourish.
- Confirm nothing unrelated is in it — stray scratch files, `.env`, editor config, vendored noise, debug prints.
- Scratch files belong in `.tmp/` at the repo root (git-ignored), never `/tmp` and never committed.

## Resume safety

A resumed run must not create a second copy of anything. Before creating, look:

```bash
git branch --list 'feat/<slug>*'                          # branch already exists?
git worktree list                                          # worktree already exists?
bash <skill_dir>/vcs.sh pr-list-head feat/<slug>            # PR/MR already open? → update it, don't open another
bash <skill_dir>/vcs.sh issue-search '<slug>'               # issue already filed?
```

`vcs.sh` (in feature-team) is forge-agnostic — it detects GitHub/GitLab/Gitea from
`origin` and drives `gh`/`glab`/`tea` accordingly, so these checks work the
same regardless of which forge the repo is hosted on.

Reuse what exists. One slug ⇒ one branch, one worktree per workstream, one issue, one PR/MR.

## Conflicts and CI

- On a real merge conflict: stop and report it with the conflicting paths. Do not force a resolution you cannot justify, and do not take one side wholesale to make it go away.
- Report CI failures verbatim (job, step, error) rather than guessing at a fix from the job name.

## Out of scope here

Repository permissions, branch protection, and CI security settings are not yours to change — see feature-security. Who creates which branch and when, and the PR/issue lifecycle, are orchestration — see feature-team and feature-pm.
