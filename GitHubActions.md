# GitHub Actions Engineering Journal

## Milestone 1 — Runner Provisioning & Repository Checkout

### Business Problem
A CI/CD platform cannot execute deployment commands unless an execution environment exists and the project source code is available. This milestone establishes the minimum workflow required to verify that GitHub can provision an ephemeral runner and populate it with the repository contents.

### Engineering Decision
A lightweight verification workflow was created before introducing deployment logic. The workflow intentionally performs no SSH or Docker operations. Instead, it validates three foundational assumptions:
- GitHub correctly detects workflow events.
- An Ubuntu runner is provisioned successfully.
- The repository is checked out and accessible inside the runner.

This staged approach isolates infrastructure validation from deployment logic, making future failures significantly easier to diagnose.

## ADR 01 — Runner Execution Strategy & Pipeline Pivot

### Context
The deployment pipeline was initially designed around standard, cloud-managed GitHub-hosted runners (`runs-on: ubuntu-latest`). This is the default approach for repository-driven CI/CD execution vectors.

During initial workflow staging and repository delivery, pipeline orchestration could not be scheduled. The execution layer failed to allocate an ephemeral computer environment due to upstream GitHub platform account billing restrictions. While the configuration syntax successfully cleared parsing verification, no execution workspace environment was provisioned by the platform pool.

### Options Considered

#### Option 1 — Wait for GitHub-hosted runners

Advantages:
- Standard cloud-hosted execution model.
- No infrastructure maintenance.

Disadvantages:
- Prevented completion of the assignment within the submission timeline.
- No ability to validate or demonstrate the deployment pipeline.

#### Option 2 — Self-hosted GitHub Actions Runner

Advantages:
- Fully supported by GitHub Actions.
- Removes dependency on GitHub-hosted runner availability.
- Executes deployment directly on the target infrastructure.
- Allows end-to-end validation of the deployment workflow.

Disadvantages:
- Runner lifecycle becomes the responsibility of the infrastructure owner.
- Runner must be maintained as a background service.

### Decision

A self-hosted GitHub Actions runner was selected for this assignment to guarantee end-to-end automation within the project timeline while remaining fully compatible with the GitHub Actions platform.

This decision preserves the same event-driven workflow model while changing only the execution environment from GitHub-hosted infrastructure to infrastructure owned by the project.


### Architectural & Security Impact Matrix

#### Original Theoretical Pipeline Design
```text
Developer
  ↳ git push
    ↳ GitHub Event
      ↳ GitHub-Hosted Runner (ubuntu-latest)
        ↳ SSH Authentication Loop via SECRETS
          ↳ Target Compute Host (EC2: 52.70.212.146)
            ↳ Docker Compose Stack Execution
```

#### Remediated Production Pipeline Design
```text
Developer
  ↳ git push
    ↳ GitHub Event
      ↳ Self-Hosted Runner Daemon (EC2: 52.70.212.146)
        ↳ Localized Docker Compose Shell Execution
```

**Key Architectural Engineering Trade-Off:** 
By installing the runner directly on the target deployment environment, the need for an external SSH network hop (`appleboy/ssh-action` or `appleboy/scp-action`) is completely eliminated. The runner executes build steps natively inside the target VM file system. This drastically reduces the attack surface by minimizing external authentication points and streamlining container management loops.

### Verification

The verification workflow successfully demonstrated:

- GitHub detected the push event.
- The self-hosted runner accepted the job.
- Repository checkout completed successfully.
- Repository contents became available inside the runner workspace.
- Shell commands executed successfully under the ubuntu service account.

### Milestone 1 Validation Output & Results
The runner configuration strategy successfully initialized on the cloud host. On-screen logs from the pipeline dashboard confirmed complete foundational stability:
- **Observed User Identity:** `ubuntu` (Confirmed direct execution inside the local EC2 machine context).
- **Observed Working Directory:** `/home/ubuntu/actions-runner/_work/realtime-chat-app/realtime-chat-app`
- **File System State:** Verified that `actions/checkout@v4` successfully established, synchronized, and unpacked the full codebase footprint into the localized daemon workspace.

All three baseline assumptions have passed testing. The automation layer is verified and ready to accept operational application delivery blocks.


### Lessons Learned

A GitHub Actions workflow is independent of the execution environment.

The same workflow can execute on:

- GitHub-hosted runners
- Self-hosted runners

without changing the overall workflow architecture.

Only the execution environment changes.

---

## ADR 02 — Deployment Workspace Allocation Strategy

### Context
Since the GitHub Actions runner agent is deployed natively inside our target staging instance, a structural workspace mapping choice must be settled. We must determine whether the container orchestration loop should run straight from the runner’s internal work directory or inside a decoupled, separate deployment directory on the host.

### Options Considered

#### Option A — Decoupled Host Production Directory
- **Advantages:** Absolute separation of operational domains; allows wiping, re-installing, or updates to the GitHub Actions runner binaries without risking downtime or modifications to the active application source paths.
- **Disadvantages:** Increases pipeline step layout complexity under tight submission time limits by introducing an explicit secondary local directory synchronization pass (e.g., `rsync` or local copy).

#### Option B — Direct Runner Workspace Execution
- **Advantages:** Highly streamlined automation pipeline; less configuration script overhead; container lifecycle tools execute directly out of the runner's ephemeral checkout block, fully answering the core assignment automation constraints.
- **Disadvantages:** Directly couples the running containers to the internal hidden paths managed exclusively by the runner daemon (`_work/...`).

### Decision & Trade-Off Evaluation
**Selected: Option B (Direct Runner Workspace Execution).**

Given the close project submission deadline, Option B provides the fastest and most reliable path to end-to-end automation with the lowest probability of execution failure. This architectural trade-off is accepted for the staging scope of this assignment. In a permanent enterprise cloud environment, Option A would be explicitly deployed to guarantee clean operational decoupling between integration agents and production runtimes.

### Deployment Directory Isolation & Decoupling Strategy

The staging architecture implements a completely decoupled directory model to isolate CI/CD framework tasks from runtime application assets. While the self-hosted GitHub Actions runner daemon checks out source repositories natively into its internal hidden workspace (`_work/...`), the operational application stack executes out of a separate dedicated directory (`/home/ubuntu/realtime-chat-app`).

#### Core Engineering Advantages
- **Infrastructure Resilience:** The self-hosted runner binaries can be wiped, updated, or completely re-installed without modifying the underlying source files or introducing active downtime to the running application containers.
- **Predictable Paths:** Application paths remain completely invariant, decoupled from the runner daemon's dynamic, hidden directory configurations.
- **Enterprise Alignment:** This matches professional, enterprise-grade architecture workflows where compilation agents and target delivery perimeters operate within strictly bounded, separate execution domains.

---

## Milestone 3 — Manual Deployment Sequence Validation

### Business Problem

Before automating deployment, the deployment commands themselves must be validated manually. Automating unverified commands can make debugging significantly more difficult because failures become intertwined with the automation platform.

### Engineering Decision

The deployment sequence was executed manually from the dedicated application directory before being incorporated into the GitHub Actions workflow.

Validated sequence:

1. Navigate to the deployment directory.
2. Synchronize the repository using `git pull`.
3. Rebuild and restart the application stack using `docker-compose up -d --build`.

This establishes a known-good deployment procedure that can later be automated with confidence.

### Verification

The deployment sequence will be considered validated after:

- `git pull` completes successfully.
- Docker Compose rebuilds the application.
- The required containers are running and healthy.


### Operational Verification Evidence

Before integrating the deployment sequence into the GitHub Actions workflow, the complete deployment process was executed manually on the target EC2 instance. This follows a fundamental DevOps engineering principle:

> Never automate a deployment process that has not first been validated manually.

### Validation Commands

```bash
cd /home/ubuntu/realtime-chat-app

git status
git pull
docker-compose up -d --build

docker ps
```

### Purpose of Each Validation Step

| Command | Engineering Purpose |
|---------|---------------------|
| `git status` | Verify that the deployment repository is in a clean state with no uncommitted or unexpected local modifications before updating the application. |
| `git pull` | Synchronize the deployment directory with the latest repository state, ensuring that production uses the newest committed source code. |
| `docker-compose up -d --build` | Rebuild application images when required, recreate modified containers, and start the complete application stack in detached mode. |
| `docker ps` | Confirm that all expected containers are running successfully after deployment and that the application runtime is operational. |

### Verification Results

The deployment sequence completed successfully.

Observed verification signals:
- `git status` reported a clean working tree.
- `git pull` confirmed the deployment repository was already synchronized with the remote repository.
- Docker Compose successfully built the backend image and created the required application containers.
- Runtime verification confirmed both application services entered the **Up** state.

Validated runtime:

| Container | Status |
|-----------|--------|
| `chat-backend` | Running |
| `chat-nginx` | Running |

### Engineering Outcome

This manual verification established a known-good deployment procedure before introducing workflow automation.

By validating the deployment sequence independently of GitHub Actions, any future failures can be isolated to the automation layer rather than the deployment commands themselves, significantly simplifying troubleshooting and reducing operational risk.

### Operational Principle

The deployment commands were intentionally validated through direct execution before being embedded into the GitHub Actions workflow.

This follows an incremental automation strategy where manual processes are first proven reliable, then automated without altering their execution logic. This approach minimizes deployment risk and improves the traceability of failures during CI/CD implementation.

---

## Milestone 4 — Automated Continuous Deployment

### Business Problem

Although the deployment process had been validated manually, it still depended on an engineer connecting to the server and executing deployment commands. This introduced unnecessary operational effort and increased the possibility of human error.

### Engineering Decision

The validated deployment sequence was incorporated into a GitHub Actions workflow executed by a self-hosted runner installed on the deployment server.

The workflow performs the following operations automatically after every push to the `main` branch:

1. Trigger the workflow.
2. Execute on the self-hosted runner.
3. Navigate to the dedicated deployment directory.
4. Synchronize the repository using `git pull`.
5. Build and update the application using `docker-compose up -d --build`.
6. Verify that the application containers are running using `docker ps`.

### Deployment Flow

```
Developer
    │
    ▼
Git Push
    │
    ▼
GitHub Actions
    │
    ▼
Self-hosted Runner
    │
    ▼
Application Directory
    │
    ▼
git pull
    │
    ▼
docker-compose up -d --build
    │
    ▼
docker ps
    │
    ▼
Deployment Complete
```

### Engineering Benefits

- Eliminates manual deployment activities.
- Ensures every deployment follows the same validated process.
- Uses an idempotent deployment command that safely handles repeated executions.
- Separates CI infrastructure from the application deployment directory.
- Includes post-deployment verification to confirm that application services are running successfully.

