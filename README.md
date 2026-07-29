# Real-Time Chat Application — DevOps Engineering Assignment

## 1. Project Overview

This repository contains a production-style staging environment for a real-time chat application. The assignment presented a deliberately misconfigured codebase and required end-to-end resolution: debugging broken container networking, restoring the NGINX reverse proxy, and deploying the corrected stack to a cloud environment with fully automated CI/CD.

The work covers four engineering domains:

- Container debugging and local deployment via Docker Compose
- Cloud infrastructure provisioning via Terraform
- Automated deployment via GitHub Actions with a self-hosted runner
- Documentation of architectural decisions, incidents, and verification results

---

## 2. Assignment Objective

The repository was provided as a deliberately misconfigured staging environment. The backend application logic was intentionally left unchanged. The objective was to identify and repair all infrastructure and deployment failures, then extend the environment to the cloud with full automation.

Core responsibilities:

- Docker container debugging
- Docker Compose service orchestration
- Container networking and DNS resolution
- NGINX reverse proxy configuration
- WebSocket protocol proxying
- Cloud infrastructure provisioning via Infrastructure as Code
- CI/CD pipeline design and automation

---

## 3. Key Features

| Feature | Implementation |
| :--- | :--- |
| Containerized backend | Python FastAPI served by Uvicorn inside a Docker container |
| Multi-container orchestration | Docker Compose manages backend and NGINX as a coordinated stack |
| NGINX reverse proxy | Static frontend served at `/`, WebSocket traffic proxied at `/ws` |
| WebSocket support | Full-duplex real-time messaging via the `/ws` endpoint |
| Infrastructure as Code | Terraform provisions EC2, Security Group, Key Pair, and Elastic IP |
| Automated deployment | GitHub Actions triggers `docker-compose up -d --build` on every push to `main` |
| Self-hosted CI/CD runner | Runner installed on the target EC2 instance, eliminating SSH hop and external secrets |
| Elastic IP stability | Static public IP persists across infrastructure teardown and rebuild cycles |

---

## 4. Repository Structure

```
realtime-chat-app/
├── app/
│   ├── main.py              # FastAPI application — WebSocket handler and connection manager
│   └── requirements.txt     # Python runtime dependencies
├── docs/
│   └── images/
│       ├── architecture.png      # Architecture diagram
│       ├── application.png       # Browser screenshot of deployed application
│       └── github-actions.png    # GitHub Actions workflow screenshot
├── frontend/
│   └── index.html           # Single-page chat client; connects via WebSocket
├── terraform/
│   └── main.tf              # Full AWS infrastructure definition (EC2, SG, EIP, Key Pair)
├── .github/
│   └── workflows/
│       └── deploy.yml       # GitHub Actions workflow — triggered on push to main
├── Dockerfile               # Builds the Python backend image
├── docker-compose.yml       # Composes backend and NGINX services
├── nginx.conf               # NGINX routing — static files and WebSocket proxy rules
├── BugFix.md                # Troubleshooting guide — six incidents with root cause analysis and resolution
├── CloudDeployment.md       # Cloud deployment guide — infrastructure provisioning and verification
└── GitHubActions.md         # CI/CD implementation guide — pipeline configuration and runner setup
```

---

## 5. Architecture

The diagram below illustrates the full deployment pipeline, from developer push through GitHub Actions and the self-hosted runner to the Docker Compose stack on EC2.

![Architecture Diagram](docs/images/architecture.png)

---

## 6. Live Application

The screenshots below document successful deployment of the application stack, verified through end-to-end operational testing. Full verification details are in [Section 13 — Operational Validation](#13-operational-validation).

### Browser

![Application Screenshot](docs/images/application.png)

The browser loads the frontend through NGINX and communicates with the FastAPI backend using WebSockets.

### GitHub Actions

![GitHub Actions Workflow](docs/images/github-actions.png)

Successful GitHub Actions deployment executed on the self-hosted runner after pushing to the `main` branch.

---

## 7. Technology Stack

| Category | Technology |
| :--- | :--- |
| **Backend** | Python 3.11, FastAPI, Uvicorn, WebSockets |
| **Frontend** | HTML5, Vanilla JavaScript (WebSocket API) |
| **Containers** | Docker, Docker Compose |
| **Reverse Proxy** | NGINX (Alpine) |
| **Infrastructure** | Terraform, AWS EC2 (t3.micro), AWS Elastic IP, AWS Security Group |
| **CI/CD** | GitHub Actions, self-hosted runner |
| **Cloud** | AWS (us-east-1), Ubuntu 22.04 LTS (Canonical AMI) |

---

## 8. Quick Start

```bash
git clone https://github.com/Anshuman-git-code/realtime-chat-app.git
cd realtime-chat-app
docker-compose up -d --build
```

Open `http://localhost` in a browser once both containers are running.

For full deployment details and the automated cloud workflow, see [Deployment Workflow](#9-deployment-workflow) below.

---

## 9. Deployment Workflow

### Local

```bash
docker-compose up -d --build
# Application available at http://localhost
```

Both containers must be running (`chat-backend` and `chat-nginx`) before the WebSocket endpoint becomes reachable.

### Cloud (Automated)

Every push to the `main` branch triggers the GitHub Actions workflow defined in `.github/workflows/deploy.yml`. The self-hosted runner — installed directly on the EC2 instance — executes the following sequence:

1. Checkout the latest repository state
2. Navigate to the deployment directory on the host
3. Run `git pull` to synchronize source files
4. Run `docker-compose up -d --build` to rebuild and restart modified containers
5. Run `docker ps` to confirm both services entered the running state

Because the runner executes natively on the target host, no SSH credentials or external secrets are required in the deployment path.

Full pipeline configuration, self-hosted runner setup, and deployment verification are documented in [GitHubActions.md](./GitHubActions.md).

---

## 10. Documentation Index

| Document | Contents |
| :--- | :--- |
| [BugFix.md](./BugFix.md) | Troubleshooting guide documenting six implementation incidents across Docker, Terraform, SSH, and CI/CD. Each incident includes symptoms, investigation process, root cause, resolution, verification, and engineering lessons learned. |
| [CloudDeployment.md](./CloudDeployment.md) | Cloud deployment guide covering Terraform infrastructure provisioning, EC2 server preparation via `user_data`, Docker Compose application deployment, and a full deployment verification record including the free-tier incident and immutable infrastructure smoke test. |
| [GitHubActions.md](./GitHubActions.md) | CI/CD implementation guide covering the GitHub Actions workflow configuration, self-hosted runner setup and rationale, manual deployment validation, deployment verification, current pipeline characteristics, and known limitations. |

---

## 11. Verification Summary

The following table documents the verification activities performed during implementation to confirm that each component of the stack operates correctly end-to-end.

| Verification Target | Method | Result |
| :--- | :--- | :--- |
| Container networking | `docker ps`, multi-tab WebSocket session | Both containers running; messages broadcast in real time |
| NGINX static file serving | Browser access to `http://localhost` | Chat UI loads correctly |
| WebSocket proxy | Browser DevTools network panel, `/ws` connection state | Persistent connection established; no handshake failures |
| Container restart policy | `docker exec chat-nginx nginx -s stop` followed by `docker ps` | NGINX container restarted automatically via `restart: always` |
| Terraform provisioning | `terraform apply`, SSH to Elastic IP | EC2 accessible; Docker daemon running; no manual setup required |
| Elastic IP persistence | Infrastructure destroy and rebuild | Same public IP retained across full teardown-rebuild cycle |
| GitHub Actions deployment | Push to `main`, Actions log review | Workflow triggered; containers rebuilt and verified on EC2 |

---

## 12. Future Production Improvements

The current implementation is scoped to a staging environment. Moving toward production readiness would require:

- **HTTPS / TLS termination** — Add a certificate (Let's Encrypt or ACM) and configure NGINX to handle TLS. The frontend WebSocket client already supports `wss:` via protocol detection.
- **Load balancing** — Introduce an AWS Application Load Balancer with sticky sessions or connection-aware routing for WebSocket traffic across multiple backend instances.
- **Auto Scaling** — Define an Auto Scaling Group to handle variable connection load, particularly relevant for a stateful WebSocket workload.
- **Secrets management** — Move any credentials and keys into AWS Secrets Manager or SSM Parameter Store rather than relying on key files referenced from local disk paths.
- **Observability** — Add structured logging (e.g., CloudWatch Logs), metrics collection, and alerting to monitor active connection counts and container health.
- **Remote Terraform state** — Migrate `terraform.tfstate` to an S3 backend with DynamoDB locking to support collaborative infrastructure management and prevent state corruption.
- **Security group hardening** — Port 22 is currently open for administrative access and assignment evaluation purposes. This project uses a self-hosted GitHub Actions runner installed directly on the EC2 instance, so outbound SSH from a runner is not required in the deployment path. In a production environment, SSH ingress should be restricted to trusted IP ranges or replaced with a more secure administrative access mechanism such as AWS Systems Manager Session Manager.

---

## 13. Operational Validation

This project was validated through end-to-end operational testing across every layer of the stack — local container runtime, host networking, AWS infrastructure, CI/CD pipeline, and live cloud deployment. Validation was not limited to code review; each component was exercised under real operating conditions and the results were observed directly.

| Validation Area | Verification Method | Result |
| :--- | :--- | :--- |
| Local Docker Deployment | `docker-compose up -d --build` executed locally | Backend image built successfully; both containers started; application accessible at `http://localhost` |
| Docker Containers | `docker ps` output reviewed | `chat-nginx` and `chat-backend` running and healthy throughout testing |
| Docker Networking | Backend reached via `backend:8000` from NGINX container | Docker internal DNS resolution confirmed; no `localhost` dependency remaining |
| Backend Availability | Uvicorn startup logs; `/ws` endpoint tested | FastAPI bound to `0.0.0.0:8000`; WebSocket endpoint responding correctly |
| NGINX Reverse Proxy | Static asset requests and proxy requests observed | Frontend served at `/`; requests forwarded to backend correctly; no routing failures |
| WebSocket Communication | WebSocket upgrade headers verified; NGINX access log showed HTTP 101 | WebSocket handshake completed; bidirectional connection established |
| Multi-user Chat | Multiple browser tabs opened simultaneously | Messages sent from one tab appeared immediately in all other tabs; real-time broadcast confirmed |
| Restart Policy | NGINX process stopped intentionally inside container; `docker ps` observed | Container restarted automatically; `restart: always` policy confirmed operational |
| AWS Infrastructure | `terraform apply` completed; SSH session established to EC2 | EC2 provisioned; Security Group enforced; `user_data` bootstrapped Docker without manual intervention |
| Elastic IP | EIP associated via Terraform; application accessed via public IP | `http://52.70.212.146` reachable; EIP persisted across full infrastructure teardown and rebuild |
| GitHub Actions | Push to `main` triggered workflow; Actions log reviewed | Runner accepted job; `git pull` and `docker-compose up -d --build` executed; containers confirmed running |
| Self-hosted Runner | Runner daemon verified on EC2; deployment path inspected | Runner executing natively from `/home/ubuntu/realtime-chat-app`; no SSH hop required |
| Terraform State | `terraform plan` executed against live AWS | Output: `No changes. Infrastructure matches configuration.` Zero drift confirmed |
| Production Infrastructure | Live AWS CLI verification of all network layers | Security Group, Route Table, Internet Gateway, Network ACL, EIP, Docker networking, host networking, iptables, UFW, NGINX, and backend all confirmed healthy |

### Engineering Outcome

These validation activities collectively confirm the following:

- **Infrastructure provisioning** — Terraform correctly provisioned and maintained all AWS resources. Live state matched declared configuration with zero drift at the time of verification.
- **Container orchestration** — Docker Compose successfully managed the multi-container stack. Both services started, communicated over the internal bridge network, and recovered from process failures without operator intervention.
- **Reverse proxy configuration** — NGINX correctly served static assets, proxied HTTP requests to the backend, and upgraded WebSocket connections. All three bugs present in the original misconfigured codebase were resolved and confirmed working.
- **Real-time communication** — The WebSocket endpoint accepted connections from multiple concurrent clients and broadcast messages correctly, validating the full NGINX-to-backend communication path.
- **CI/CD deployment** — The GitHub Actions workflow successfully automated the full deployment sequence on every push to `main`, executing natively on the self-hosted runner without requiring external SSH access or stored credentials.
- **Infrastructure as Code consistency** — Terraform state remained consistent with the live AWS environment throughout the project lifecycle, including after infrastructure teardown and rebuild.
- **End-to-end deployment** — The application was verified accessible externally via the Elastic IP from a remote host, completing the full path from developer workstation through GitHub Actions to a publicly reachable cloud deployment.

---

## 14. Production Considerations

The current implementation was intentionally designed to satisfy the assignment objectives while following DevOps best practices. The architecture prioritises clarity, reproducibility, and demonstration of infrastructure provisioning, container orchestration, and CI/CD automation over the operational complexity associated with high-availability production systems. The decisions documented below reflect that intent and are appropriate for the scope of this assignment.

| Current Implementation | Production Evolution | Engineering Benefit |
| :--- | :--- | :--- |
| HTTP only | HTTPS via Let's Encrypt or AWS ACM | Encrypts client communication; required for WebSocket Secure (`wss://`) |
| Elastic IP pointing directly to EC2 | AWS Application Load Balancer | Health checks, TLS termination, and traffic distribution across instances |
| Single EC2 instance | Multiple EC2 instances behind an Auto Scaling Group | Fault tolerance; automatic capacity adjustment under variable load |
| Docker Compose on a single host | Amazon ECS or Amazon EKS | Managed container orchestration; rolling deployments; horizontal scaling |
| Container images built directly on EC2 | Versioned images stored in Amazon ECR | Reproducible builds; image vulnerability scanning; faster deployments |
| Environment variables stored locally | AWS Secrets Manager or AWS Systems Manager Parameter Store | Centralised, auditable, and access-controlled credential management |
| Container-level logging only | Amazon CloudWatch, Prometheus, or Grafana | Centralised metrics, dashboards, and alerting for operational visibility |
| `docker-compose up -d --build` in-place deployment | Rolling or Blue/Green deployment strategy | Reduced deployment downtime; safer release process; instant rollback capability |
| Single deployment, no backup strategy | Automated backups, multi-AZ deployment, infrastructure recovery | Improved resilience and continuity in the event of instance or AZ failure |
| Container stdout/stderr logs | Centralised logging via CloudWatch Logs or ELK Stack | Structured log aggregation; simplified troubleshooting across distributed services |

### Architectural Evolution

The current architecture — a single EC2 instance running Docker Compose — is a deliberate choice for this assignment. It provides a fully functional, reproducible deployment environment that clearly demonstrates infrastructure provisioning with Terraform, container orchestration with Docker Compose, reverse proxy configuration with NGINX, and automated deployment with GitHub Actions. Introducing additional components such as load balancers, managed container platforms, or distributed databases would add operational overhead without contributing to the core learning objectives.

Production systems require additional components not because the application code changes, but because the operational requirements change. A system serving real users at scale must tolerate instance failures, handle concurrent traffic spikes, protect credentials, provide operational visibility, and deploy new releases without service interruption. Each item in the table above addresses one or more of these requirements. None of them alter the application's business logic — they extend the infrastructure and deployment layers that surround it.

The transition from this architecture to a production-grade system would be incremental rather than a full rewrite. The Terraform configuration would be extended to add an Application Load Balancer, an Auto Scaling Group, and an ECR repository. The Docker Compose workflow would be replaced by ECS task definitions or Kubernetes manifests, with the same container images managed in ECR. The GitHub Actions workflow would be updated to push images to ECR and trigger ECS deployments, preserving the same event-driven CI/CD model already in place.

The tooling chosen for this assignment — Terraform, Docker, and GitHub Actions — scales directly into production use without substitution. Terraform manages infrastructure at any scale; Docker images are the deployment unit for ECS and EKS; and GitHub Actions workflows support multi-environment deployments, approval gates, and environment-specific secrets. The patterns demonstrated here are the same patterns used in production environments, applied at a scope appropriate for a single-instance staging deployment.

The current implementation provides a solid foundation. The infrastructure is fully codified, the deployment is automated, the application is containerised, and the architecture is documented. Each production improvement listed above can be applied incrementally to this foundation without requiring the existing work to be discarded.

---

## 15. Engineering Design Decisions

Every architectural and infrastructure choice in this project was made deliberately to balance simplicity, reproducibility, and the assignment objectives. The decisions below are not defaults or shortcuts — each one reflects a considered trade-off between complexity and the value it provides within the scope of an educational DevOps assignment.

| Design Decision | Engineering Rationale | Trade-off |
| :--- | :--- | :--- |
| Terraform for infrastructure provisioning | Infrastructure becomes version-controlled and reproducible. Resources can be recreated consistently without relying on institutional knowledge or manual steps. Configuration drift is eliminated because the declared state is always the source of truth. | Higher initial learning curve than manual console provisioning, offset significantly by repeatability and auditability. |
| Dynamic AMI lookup | Avoids hardcoded AMI IDs that become stale when Canonical publishes updates. Improves portability across environments and prevents deployment failures caused by deprecated image identifiers. | OS-level updates introduced by a new AMI should be tested before being applied to a production environment. |
| Elastic IP allocation | Provides a stable, predictable public endpoint. The deployment target for GitHub Actions and any associated DNS records remain valid even if the underlying EC2 instance is replaced or rebuilt by Terraform. | Requires managing an additional AWS resource. Temporary public IPs would be simpler but would change on every instance replacement. |
| EC2 `user_data` bootstrap | Automates the installation of Docker and Docker Compose on first boot. A newly provisioned instance is immediately deployment-ready without any manual preparation steps. | Bootstrap scripts grow over time and require maintenance. Failures are harder to debug than interactive installation because output is only available in system logs. |
| Dedicated Security Group with minimum ports | Enforces least-privilege network access. Only Port 80 (application traffic) and Port 22 (administrative access) are open. No unnecessary attack surface is exposed. | HTTPS was intentionally excluded because certificate management falls outside the assignment scope, which focuses on deployment automation. |
| Docker Compose for container orchestration | Provides straightforward multi-container management with a single declarative file. The same workflow runs identically in local development and on the EC2 instance, which reduces environment-specific failures and simplifies debugging. | Not suitable for large-scale or high-availability deployments where managed orchestration platforms such as ECS or Kubernetes are the appropriate choice. |
| NGINX as reverse proxy | Consolidates all inbound traffic through a single container. Handles static file serving, HTTP reverse proxying, and WebSocket protocol upgrades from one configuration file. Clients interact with one endpoint regardless of the backend topology. | Adds one additional container to manage. The trade-off is justified by the simplification it provides to the client-facing network path. |
| FastAPI for the backend | Provides native asynchronous request handling and a first-class WebSocket implementation, which are both required by the application. Lightweight enough to run efficiently in a single container without tuning. | Framework selection was driven by assignment requirements rather than a comparative evaluation. |
| Self-hosted GitHub Actions runner on EC2 | The runner executes deployment commands directly on the target host. No SSH credentials, external secrets, or deployment scripts are required. The runner has native access to Docker and the project directory, simplifying the workflow significantly. | The runner's availability becomes a dependency of the CI/CD pipeline. If the runner process stops, deployments stop until it is restarted. Runner lifecycle is now part of infrastructure management. |
| Push-to-main automated deployment | Every commit merged to `main` triggers a full deployment automatically. The deployment sequence — `git pull` followed by `docker-compose up -d --build` — is identical whether executed manually or by the runner, which eliminates a class of environment-specific deployment bugs. | The in-place `docker-compose up` approach causes a brief window during container recreation where the application is unavailable. Production deployments would use rolling or blue-green strategies to eliminate this gap. |
| Single EC2 instance | Keeps the infrastructure footprint minimal and the operational scope aligned with the assignment objectives. All required DevOps concepts — IaC, containerisation, reverse proxying, CI/CD — are fully demonstrable on a single host. | Creates a single point of failure. This is an accepted and appropriate trade-off for an educational assignment where availability is not an evaluated requirement. |

### Design Philosophy

Reproducibility is one of the most important properties of a well-engineered infrastructure. An environment that can only be created by following undocumented manual steps carries significant operational risk — it cannot be reliably recreated after a failure, it cannot be shared with another engineer without knowledge transfer, and it accumulates configuration drift over time as changes are made without being recorded. Terraform addresses this directly by making the infrastructure definition the canonical record of what should exist, and by detecting and correcting any deviation from that record.

Automation reduces operational risk not by removing human judgement, but by removing unnecessary human intervention from processes that should be deterministic. A deployment that runs the same commands in the same order every time is safer than one that depends on an engineer remembering the correct sequence. The GitHub Actions workflow in this project encodes the deployment process once and executes it consistently. The same principle applies to the `user_data` bootstrap — the server configuration is defined once and applied automatically on every new instance, rather than being re-executed from memory each time.

Engineering decisions always involve trade-offs. There is no choice that is unconditionally correct across all contexts. Docker Compose is the right tool for this assignment because simplicity and clarity are the priority. It would not be the right tool for a system that must scale horizontally or survive the failure of a single host. A Security Group that exposes Port 22 to `0.0.0.0/0` is a reasonable trade-off for an assignment where the runner executes from a dynamic environment; it would not be acceptable in a production system where SSH access should be restricted or replaced entirely. Recognising the conditions under which a decision is valid — and the conditions under which it must be revisited — is what separates deliberate architecture from accidental configuration.

The technologies selected for this project fit the assignment scope because they are widely adopted, well-documented, and demonstrate transferable skills. Terraform, Docker, NGINX, and GitHub Actions are used in production environments at scale. Using them here, even in a simplified context, provides practical familiarity with the same tools and patterns that appear in larger systems. The concepts demonstrated — infrastructure as code, containerisation, reverse proxying, CI/CD automation — are not specific to the scale of this deployment. They apply equally to a single EC2 instance and to a multi-region distributed system.

Production systems often require different technology choices not because the engineering principles change, but because the operational constraints do. A system that must handle thousands of concurrent users, maintain uptime guarantees, and support a team of engineers deploying multiple times per day requires managed orchestration, centralised observability, and zero-downtime deployment strategies. Those requirements are absent here, which is why the simpler choices are appropriate. The value of understanding this distinction is that it enables an engineer to choose correctly for the context rather than applying the same solution regardless of requirements.

The design decisions in this project prioritise maintainability, reproducibility, and automation while remaining intentionally scoped for an educational DevOps assignment. The infrastructure is codified, the deployment is automated, and the trade-offs are documented — which means any engineer reviewing this project can understand not just what was built, but why.

---

## 16. Conclusion

This project demonstrates practical DevOps engineering across the full deployment lifecycle: diagnosing and resolving container networking and proxy configuration failures, provisioning reproducible cloud infrastructure with Terraform, and delivering a fully automated deployment pipeline with GitHub Actions. The result is a working staging environment where a single push to `main` rebuilds and redeploys the application stack without manual intervention.

The repository reflects a production-style staging deployment that balances assignment constraints with engineering best practices: deliberate architectural decisions are documented as ADRs, known trade-offs are acknowledged explicitly, and the verification record provides an auditable trail from local debugging through to cloud deployment.
