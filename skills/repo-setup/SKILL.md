---
name: repo-setup
description: "Sets up a repo's CI/CD pipeline, infrastructure-as-code, and deployment configuration by detecting what already exists (CI config, Dockerfiles, IaC files, package manager, existing deploy configs) and interviewing the user one question at a time about what's missing — CI provider, cloud/hosting target, IaC tool, containerization, environments and promotion strategy, secrets management — then writing the actual config files (workflows, IaC modules, Dockerfiles, deployment manifests), not just a design doc. Use when a repo has no CI/CD, infra, or deploy setup yet, or when the user wants to add to or redesign one. Does not provision cloud accounts, run terraform apply/deploy commands against live infrastructure, or write real secret values — it writes config with placeholders and tells the user what manual step remains."
---

You are setting up (or filling gaps in) a repo's CI/CD, infrastructure-as-code, and
deployment configuration. This is a single-agent skill — no Herdr, no subagent
spawning, no role-contract siblings. The operating principle is: detect what already
exists, ask about the rest, confirm, then write the actual files. Never assume a
default stack (GitHub Actions + Terraform + Docker is one possible answer, not a
hardcoded default). One question at a time during the interview — no compound
questions.

## Steps

### 1. Detect current repo state

Read-only scan of the target repo for existing signals in four categories: CI
config, infrastructure-as-code, containerization, and package manager / monorepo
tooling / existing deployment platform config. See
[reference/detection-signals.md](reference/detection-signals.md) for the full
file-glob lookup table to check against.

Also check for existing alternate IaC directory names (`deploy/`, `ops/`,
`deployment/`, `infrastructure/`) before ever defaulting a new IaC scaffold to
`infra/`.

Summarize what you found in prose before asking anything — e.g. "This repo has no
CI config, a `Dockerfile`, and a `package.json` with `pnpm-workspace.yaml` (looks
like a monorepo). No IaC or deployment config detected." Infer likely defaults from
what's visible, but confirm them in the interview rather than assuming.

### 2. Confirm scope for this run

Ask one question: which of **CI/CD**, **infrastructure-as-code**, and
**deployment** (any subset, or all three) should this run touch? Never silently
touch a category the user didn't confirm — if they only want CI/CD set up today,
leave IaC and deployment alone even if they're missing.

### 3. Interview, one topic at a time

For each in-scope topic from Step 2, ask one question at a time. For each
question: give a short recommendation inferred from Step 1's detection, add a
one-line self-check (what could be wrong with this pick), wait for the answer,
then briefly check it against earlier answers before moving to the next question
(e.g. flag a mismatched combo like "Vercel as host" + "Terraform for AWS" as IaC).

Topics, in order:

1. **CI provider** — keep the one detected in Step 1, or choose a new one
   (GitHub Actions / GitLab CI / CircleCI / Jenkins / other).
2. **Cloud/hosting target** — AWS / GCP / Azure / Vercel / Netlify / Fly / Render /
   self-hosted / other.
3. **IaC tool** — Terraform / Pulumi / CDK / CloudFormation / Ansible / none (a PaaS
   target like Vercel or Render may need none).
4. **Containerization** — Docker, or not (some PaaS targets use buildpacks
   instead — don't force a Dockerfile on them).
5. **Environments and promotion strategy** — dev/staging/prod, branch-based vs
   tag-based triggers, manual approval gates.
6. **Secrets management approach** — the CI provider's own secret store, a cloud
   secrets manager, Vault, sops, 1Password, etc. State explicitly that this skill
   never writes real secret values, only references/placeholders.

If the repo's monorepo tooling was detected in Step 1, also ask whether each
service/package needs its own CI/deploy config or whether one shared pipeline
covers all of them.

### 4. Draft the file manifest and confirm

Show a table: file path → purpose → action (create / modify / leave alone). For
any category where Step 1 found an existing file, offer a three-way choice per
artifact type: **update** (merge in the new pieces), **overwrite** (back up the
existing file first, e.g. to `<file>.bak`), or **leave alone**. Ask once for
confirmation before writing anything. If the user requests changes, apply them and
re-confirm — don't loop more than a couple of rounds; if alignment is hard, write
the current draft and say what's left to adjust manually.

### 5. Write the files

This is the step that makes this skill an implementer, not a planner — actually
write the files agreed in Step 4:

- CI workflow(s) at the agreed path (e.g. `.github/workflows/ci.yml`,
  `.github/workflows/deploy.yml`).
- IaC scaffold under the agreed directory (default `infra/` only if Step 1 found
  no existing alternate name and the user has no preference), using the chosen
  tool's idiomatic layout.
- `Dockerfile` / `docker-compose.yml` if containerization is in scope and missing.
- Deployment manifest/config matching the chosen target (Kubernetes manifests,
  PaaS config file, `Procfile`, `serverless.yml`, etc.).
- Add the standard ignore entries for what was just created to the *target repo's*
  `.gitignore` (e.g. `.terraform/`, `*.tfstate*`, and `.env` if a `.env.example`
  was created) — not this skills repo's `.gitignore`.

Use placeholders/references for anything secret-shaped (`${{ secrets.X }}`,
`var.x`, etc.) — never a real value.

### 6. Write the setup record

Default to writing (or updating) a single `docs/infra/setup.md` in the target
repo, containing: date, a decisions table (CI provider, IaC tool, cloud target,
environments, secrets approach), the file manifest from Step 4, and a short note
on how to re-run this skill later to extend the setup. Ask once whether to write
it at all — default yes, but respect a "skip" answer.

If Step 3 concluded the repo needs per-service configs (monorepo case), write one
record per service instead: `docs/infra/<service-slug>.md`.

### 7. Next steps

Tell the user what remains manual, since this skill never does these itself:
creating the cloud account/project if it doesn't exist, setting the real secret
values in the CI provider's UI or secrets manager, the first
`terraform apply`/`pulumi up`/deploy invocation, DNS, and confirming the pipeline
goes green on the first push.

## Important rules

- Never runs `terraform apply` / `pulumi up` / any real deploy command against
  live infrastructure — writes config only.
- Never writes real secret values — placeholders/references only.
- Never assumes a default stack — always detect, then ask.
- One question at a time during the interview. No compound questions.
- Single agent — no Herdr, no subagent spawning, no role-contract siblings.
- Only touches the subset of CI/IaC/deployment the user confirmed in Step 2 —
  never silently expands scope to all three.
