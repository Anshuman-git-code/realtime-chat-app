# GitHub Actions CI/CD Guide

This document covers the CI/CD pipeline implementation for this project: how the workflow is structured, how the self-hosted runner operates, how deployment is executed, and what was verified during implementation.

**Related documents:**
- [README.md](./README.md) — Project overview, architecture, engineering decisions, and production considerations
- [CloudDeployment.md](./CloudDeployment.md) — Infrastructure provisioning, server preparation, and deployment verification
- [BugFix.md](./BugFix.md) — Root cause analysis for the three configuration bugs resolved during this project

---

## Pipeline Overview

Every push to the `main` branch automatically triggers a deployment. The GitHub Actions workflow pulls the latest code onto the EC2 instance and rebuilds the Docker Compose stack. No manual intervention is required after a commit is merged.

The pipeline encodes the deployment process once and executes it identically on every run. This eliminates the class of failures that arise from engineers running commands in slightly different orders or against slightly different environments.

---

## Workflow Architecture

```
Developer
    │
    ▼ git push → main
GitHub Event Trigger
    │
    ▼ runs-on: self-hosted
Self-hosted Runner (EC2: 52.70.212.146)
    │
    ▼ actions/checkout@v4
Repository Checkout
    │
    ▼ cd /home/ubuntu/realtime-chat-app && git pull
Source Synchronisation
    │
    ▼ docker-compose up -d --build
Container Rebuild and Restart
    │
    ▼ docker ps
Post-deployment Verification
    │
    ▼
Deployment Complete
```

Each stage is described in detail in the sections below.

---

## Workflow Configuration

The complete workflow is defined in `.github/workflows/deploy.yml`.

```yaml
name: Deploy Application

on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: self-hosted

    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Deploy Application
        run: |
          set -e
          cd /home/ubuntu/realtime-chat-app
          git pull
          docker-compose up -d --build

      - name: Verify Deployment
        run: |
          docker ps
```

### Trigger

```yaml
on:
  push:
    branches:
      - main
```

The workflow fires on every push to `main`. No other branches trigger a deployment. This means feature branches can be developed and committed without triggering a deployment until they are merged.

### Runner Selection

```yaml
runs-on: self-hosted
```

The job targets the self-hosted runner registered on the EC2 instance rather than a GitHub-hosted runner. See [Self-hosted Runner](#self-hosted-runner) below for the rationale.

### Step 1 — Checkout Repository

```yaml
- name: Checkout Repository
  uses: actions/checkout@v4
```

`actions/checkout@v4` clones the repository into the runner's internal workspace at:
```
/home/ubuntu/actions-runner/_work/realtime-chat-app/realtime-chat-app
```

This step was verified during initial pipeline setup. Observed outputs confirmed:
- The push event was detected by GitHub.
- The runner accepted the job.
- The repository contents were unpacked into the runner workspace.
- Commands executed under the `ubuntu` service account.

### Step 2 — Deploy Application

```yaml
- name: Deploy Application
  run: |
    set -e
    cd /home/ubuntu/realtime-chat-app
    git pull
    docker-compose up -d --build
```

| Command | Purpose |
| :--- | :--- |
| `set -e` | Fail-fast — the step exits immediately if any command returns a non-zero exit code, preventing a partially failed deployment from reaching the verification step |
| `cd /home/ubuntu/realtime-chat-app` | Switches to the dedicated application directory, which is decoupled from the runner's internal workspace |
| `git pull` | Synchronises the application directory with the latest committed state on `main` |
| `docker-compose up -d --build` | Rebuilds any images affected by code changes and recreates the corresponding containers in detached mode; services whose images are unchanged are left running |

The deployment directory `/home/ubuntu/realtime-chat-app` is intentionally separate from the runner's `_work/` path. This means the runner can be updated, reinstalled, or removed without affecting the running containers or application source files.

### Step 3 — Verify Deployment

```yaml
- name: Verify Deployment
  run: |
    docker ps
```

`docker ps` outputs the running container table immediately after deployment. If both `chat-backend` and `chat-nginx` appear in the `Up` state, the step exits cleanly and the workflow completes successfully. If either container failed to start, `docker ps` does not cause the workflow to fail — this step provides visibility rather than a health gate. A more robust check would poll the HTTP endpoint until it responds; see [Current Limitations](#current-limitations).

---

## Self-hosted Runner

### Why a self-hosted runner was used

The pipeline was originally designed to use a GitHub-hosted runner (`runs-on: ubuntu-latest`). During implementation, GitHub Actions workflow dispatch failed to allocate a hosted runner due to account-level billing restrictions on the GitHub account. Waiting for hosted runner availability was not viable within the project timeline.

A self-hosted runner was installed directly on the EC2 instance as an alternative. This is a supported GitHub Actions configuration and preserves the same event-driven workflow model — only the execution environment changes.

### How it differs from GitHub-hosted runners

| Aspect | GitHub-hosted runner | Self-hosted runner (this project) |
| :--- | :--- | :--- |
| Provisioned by | GitHub | Project owner |
| Lifecycle | Ephemeral — created and destroyed per job | Persistent — daemon runs continuously on EC2 |
| Environment | Fresh Ubuntu VM each run | Existing EC2 instance with Docker installed |
| Maintenance | None required | Runner process must be kept running |
| Access to Docker | Not pre-installed for deployment to remote hosts | Direct — Docker is installed on the same host |
| SSH required for deployment | Yes — credentials needed to reach EC2 | No — runner executes locally on the target host |

### Security impact

The original GitHub-hosted runner design required an SSH connection from the runner to the EC2 instance, which meant storing the private key as a GitHub Actions secret and exposing Port 22 to the runner's dynamic IP range. With the self-hosted runner installed on EC2, the SSH hop is eliminated entirely. The runner executes `docker-compose` directly on the host where the containers run. No external secrets are required in the deployment path.

### Runner workspace and deployment directory

The runner checks out the repository into its internal workspace:
```
/home/ubuntu/actions-runner/_work/realtime-chat-app/realtime-chat-app
```

The application runs from a separate directory:
```
/home/ubuntu/realtime-chat-app
```

The deployment step explicitly `cd`s into the application directory before running `git pull` and `docker-compose`. This decoupling means:
- The runner workspace is used only for the checkout step.
- The running containers are never dependent on the runner's internal paths.
- Updating or reinstalling the runner does not cause downtime.

---

## Manual Deployment Validation

Before the deployment sequence was embedded in the GitHub Actions workflow, it was validated manually on the EC2 instance. This followed the principle of not automating a process that has not first been confirmed to work.

The following commands were run directly on the instance:

```bash
cd /home/ubuntu/realtime-chat-app
git status
git pull
docker-compose up -d --build
docker ps
```

| Command | What it confirmed |
| :--- | :--- |
| `git status` | Working tree was clean; no unexpected local modifications |
| `git pull` | Repository successfully synchronised with the remote |
| `docker-compose up -d --build` | Backend image built successfully; both containers started |
| `docker ps` | `chat-backend` and `chat-nginx` entered the `Up` state |

Once this sequence was confirmed to produce the correct outcome manually, it was incorporated into the GitHub Actions workflow without modification. This approach means any future workflow failure can be attributed to the automation layer rather than the deployment commands themselves.

---

## Deployment Verification

The following verification activities were performed after the automated pipeline was operational.

| Verification | Method | Result |
| :--- | :--- | :--- |
| Workflow trigger | Push to `main`; Actions tab reviewed | Workflow triggered immediately; job accepted by self-hosted runner |
| Runner identity | Actions log — identity check | Executing as `ubuntu` on EC2 — confirmed local execution on target host |
| Repository checkout | Actions log — checkout step | `actions/checkout@v4` unpacked repository into runner workspace |
| Source synchronisation | `git pull` output in Actions log | Deployment directory synchronised with latest `main` commit |
| Container rebuild | `docker-compose up -d --build` log | Backend image rebuilt; both containers recreated |
| Container status | `docker ps` in Verify Deployment step | `chat-backend` and `chat-nginx` both in `Up` state |
| HTTP response | `curl http://52.70.212.146` from external host | HTTP 200 — application served correctly post-deployment |
| WebSocket connection | Browser DevTools, `/ws` connection state | HTTP 101 Switching Protocols — WebSocket handshake completed |
| Multi-user broadcast | Two browser tabs at public IP | Messages sent from one tab appeared immediately in the other |

---

## Current Pipeline Characteristics

| Characteristic | Detail |
| :--- | :--- |
| Trigger | Push to `main` branch |
| Execution environment | Self-hosted runner on EC2 |
| Deployment command | `docker-compose up -d --build` |
| Fail-fast behaviour | `set -e` — any command failure stops the workflow |
| Post-deployment check | `docker ps` confirms containers are running |
| Secrets required | None — runner executes locally on the deployment host |
| Manual steps required | None — fully automated from push to running containers |
| Deployment idempotency | `docker-compose up -d --build` safely handles repeated runs |

---

## Current Limitations

These are real characteristics of the current pipeline, not theoretical gaps.

**Brief downtime during container recreation.**
`docker-compose up -d --build` stops and recreates containers whose images have changed. There is a short window — typically a few seconds — during which the application is not serving requests. For a staging environment this is acceptable. A production deployment would use a rolling update strategy or a load balancer to eliminate the gap.

**No deployment health check.**
The `Verify Deployment` step runs `docker ps` to confirm containers are in the `Up` state. It does not poll the HTTP endpoint or the WebSocket endpoint to confirm the application is actually responding. A container can be `Up` while the process inside it is still starting. A curl-based readiness check would close this gap.

**No rollback automation.**
If `docker-compose up -d --build` succeeds but the application is unhealthy, there is no automated mechanism to revert to the previous image. A rollback requires manual intervention: SSH to the instance, identify the previous image tag, and restart the containers from it. Pinning image versions in the Compose file or pushing images to a registry before deployment would enable automated rollback.

**No deployment approval stage.**
Any push to `main` triggers an immediate deployment. There is no review gate, manual approval step, or staging environment between a merge and a production deployment. For a single-developer assignment this is appropriate; for a team environment it would introduce risk.

**No automated integration tests.**
The pipeline does not run tests before deploying. There is no step that executes the test suite, validates the application health, or gates the deployment on a passing result. Adding a test job that runs before the deploy job would catch regressions before they reach the deployed environment.

**Runner availability dependency.**
If the self-hosted runner daemon stops on the EC2 instance, all deployments queue indefinitely. There is no fallback runner. The runner must be manually restarted if it exits. Configuring the runner as a `systemd` service with `Restart=always` would provide automatic recovery.

---

## Summary

The GitHub Actions pipeline in this project demonstrates end-to-end CI/CD automation using a self-hosted runner, Docker Compose, and AWS EC2. Every push to `main` automatically pulls the latest code, rebuilds affected containers, and confirms they are running — without any manual steps. The pipeline was implemented incrementally: the runner was verified before the deployment commands were added, and the deployment commands were validated manually before being automated. This approach kept each layer independently testable and made failures straightforward to diagnose. The pipeline is intentionally simple, matching the scope of an educational DevOps assignment while applying the same automation principles used in production workflows.
