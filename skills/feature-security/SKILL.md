---
name: feature-security
description: "Internal shared contract for the feature-team skill — the safety rules every role (PM, SA, Dev, Tester) obeys around secrets, credentials, production systems, and workspace boundaries. Not a standalone workflow and not a security review of the user's code; it governs how the agents themselves behave during a feature run."
---

# Feature security contract

Binding on every role in a feature-team run. When one of these rules collides with finishing the task, the rule wins and the conflict goes to PM as a blocking question (see feature-pm § Escalation) — it is never resolved by quietly proceeding *or* by quietly skipping the work.

## Secrets

- **Access as little as you need.** Do not read `.env`, credential files, or key material out of curiosity, "to understand the config", or to check that something is set. If you need to know whether a variable exists, test for its presence, not its value.
- **Never print a credential anywhere durable or shared**: not into the tracking doc, a forge issue or PR/MR, a commit message, a log you paste back, a handoff, a worker prompt, or your own report. Redact to `<redacted>` / `FOO=***` when quoting output that contains one.
- **Never commit a secret.** If one is already committed, do not "fix" it by deleting the line in a new commit — the history still has it. Stop and escalate; rotation is a human decision.
- **Never hand a credential to another agent in plaintext.** Every agent already receives the provider/config environment it needs through feature-team's own env forwarding (`agent-env.sh`). If a worker seems to need a secret you would have to type out, that is an escalation, not a workaround.
- Do not add real values to example/config files. `.env.example` gets placeholders.

Watch especially for: `.env*`, `~/.aws`, `~/.config/gcloud`, `~/.azure`, `~/.ssh`, `~/.netrc`, `~/.docker/config.json`, GitHub/GitLab/Gitea/npm/PyPI tokens, `id_rsa`/`*.pem`/`*.key`, kubeconfigs, database URLs with embedded passwords, CI secret files, and anything under a `secrets/` directory.

## Production

- **Use development/test credentials and fixtures.** Never point tests, migrations, seeds, or a manual check at a production database, queue, bucket, or API key.
- **No destructive or production-mutating operations** unless the user's original request explicitly authorized exactly that operation: `terraform apply`, production migrations, `kubectl apply/delete` against a live cluster, `docker system prune`, dropping/truncating tables, deleting cloud resources, sending real mail/notifications/payments, rotating live credentials.
- Read-only inspection of production is still access — prefer local reproduction, and escalate if you genuinely need the real thing.

## Permissions and controls

- **Do not change repository permissions**: collaborators, branch protection, required checks, deploy keys, webhooks, secrets in repo/org settings.
- **Do not weaken CI or quality gates** to get to green: disabling a workflow or job, removing a required check, adding `continue-on-error`, `--no-verify`, skipping/xfail-ing a test that is failing for a real reason, loosening lint/type strictness, or relaxing an audit threshold. If a gate is wrong, say so and let a human decide.
- Do not silently downgrade security in the code you write either: auth checks, input validation at trust boundaries, CSRF/CORS policy, TLS verification, and permission checks stay at least as strict as you found them. Relaxing any of them is a product decision.

## Workspace boundaries

- Stay inside this repository's working trees (the main checkout and the feature's worktrees). Do not read, write, or delete elsewhere on the machine.
- No `rm -rf` outside those trees, ever. Scratch files go in `.tmp/` at the repo root.
- Do not install system-wide packages, modify the user's shell profile, or change global git/tool config. Project-local dependency changes are fine when the task calls for them — flag any new dependency to PM.
- Do not touch another agent's worktree. See feature-git § Isolation.

## Network and supply chain

- Fetching a URL sends whatever you include to a third party — do not paste repository contents, logs, or configuration into an external service.
- New dependencies need a reason: prefer what the repository already uses (see feature-sa). Do not add a package from an untrusted source, pin to a moving tag when the repo pins exactly, or disable integrity/lockfile checks.

## When something is ambiguous

Escalate to PM rather than choosing. Ambiguity worth escalating looks like: "this test only passes against the real service", "the task implies a migration on an environment I can't identify", "this credential is in the repo already", "the fix requires turning off a check", "I need permission I don't have". Report *what* you need and *why*, never with the secret itself in the message.

PM escalates these to the user as `status=blocked` — a security-sensitive unknown is a human decision by definition.
