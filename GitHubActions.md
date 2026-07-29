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
