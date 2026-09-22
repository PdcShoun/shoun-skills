# Detection signals

Lookup table of file/path signals to check for during Step 1 (Detect current repo state).
Pure reference data — no logic here, just what to look for.

## CI config

| Provider | Signals |
| --- | --- |
| GitHub Actions | `.github/workflows/*.yml`, `.github/workflows/*.yaml` |
| GitLab CI | `.gitlab-ci.yml` |
| CircleCI | `.circleci/config.yml` |
| Jenkins | `Jenkinsfile` |
| Drone | `.drone.yml` |
| Bitbucket Pipelines | `bitbucket-pipelines.yml` |
| Azure Pipelines | `azure-pipelines.yml` |
| Travis CI | `.travis.yml` |

## Infrastructure-as-code

| Tool | Signals |
| --- | --- |
| Terraform | `*.tf`, `*.tf.json`, `terraform/` |
| AWS CDK | `cdk.json` |
| Pulumi | `Pulumi.yaml`, `Pulumi.<stack>.yaml` |
| Serverless Framework | `serverless.yml`, `serverless.yaml` |
| AWS SAM | `template.yaml` (with `Transform: AWS::Serverless-2016-10-31`) |
| CloudFormation | `*.template.json`, `*.template.yaml` |
| Kubernetes manifests | `k8s/`, `kustomization.yaml` |
| Helm | `Chart.yaml`, `charts/` |
| Ansible | `playbook.yml`, `ansible.cfg`, `roles/` |

## Existing alternate IaC directory names

Check these before defaulting a new IaC scaffold to `infra/`: `deploy/`, `ops/`, `deployment/`, `infrastructure/`.

## Containerization

| Signal | Meaning |
| --- | --- |
| `Dockerfile` | App is containerized or has a container build path |
| `docker-compose.yml` / `docker-compose.yaml` | Local/multi-service container orchestration exists |
| `.dockerignore` | Confirms an active Docker build context |

## Package manager / monorepo tooling

| Ecosystem | Signals |
| --- | --- |
| Node.js | `package.json` |
| Node.js monorepo | `turbo.json`, `nx.json`, `pnpm-workspace.yaml`, `lerna.json` |
| Python | `pyproject.toml`, `requirements.txt`, `Pipfile` |
| Go | `go.mod` |
| Rust | `Cargo.toml` |
| Java/Kotlin | `pom.xml`, `build.gradle`, `build.gradle.kts` |
| Ruby | `Gemfile` |

## Existing deployment/platform config

| Platform | Signals |
| --- | --- |
| Vercel | `vercel.json` |
| Netlify | `netlify.toml` |
| Fly.io | `fly.toml` |
| Render | `render.yaml` |
| Heroku-style buildpacks | `Procfile` |
| AWS Elastic Beanstalk | `.elasticbeanstalk/`, `app.yaml` |
| ECS | task definition JSON files (look for `containerDefinitions` key) |
| Platform.sh | `.platform/`, `.platform.app.yaml` |
