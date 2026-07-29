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
