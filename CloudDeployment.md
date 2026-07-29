# Cloud Deployment Guide

This document describes how the real-time chat application is provisioned, deployed, and verified on AWS. It covers the infrastructure layer managed by Terraform, the server preparation performed by `user_data`, the application layer managed by Docker Compose, and the automated deployment pipeline executed by GitHub Actions.

**Related documents:**
- [README.md](./README.md) — Project overview, architecture, engineering decisions, and production considerations
- [GitHubActions.md](./GitHubActions.md) — CI/CD pipeline design, runner provisioning, and milestone verification
- [BugFix.md](./BugFix.md) — Root cause analysis for the three configuration bugs resolved during this project

---

## Deployment Overview

The deployment process is split into two layers.

The **infrastructure layer** is managed by Terraform. It provisions the EC2 instance, Security Group, Key Pair, and Elastic IP once. Terraform maintains a state file that tracks the live configuration and detects any drift from the declared state.

The **application layer** is managed by Docker Compose and deployed automatically on every push to `main` via GitHub Actions. The self-hosted runner, installed directly on the EC2 instance, executes `git pull` and `docker-compose up -d --build` without requiring an external SSH hop.

```
Infrastructure (Terraform — run once)        Application (GitHub Actions — run on every push)
──────────────────────────────────────       ──────────────────────────────────────────────────
terraform apply                              git push → main
  → EC2 instance                               → GitHub Actions triggered
  → Security Group                               → Self-hosted runner (on EC2)
  → Key Pair                                       → git pull
  → Elastic IP                                       → docker-compose up -d --build
  → user_data bootstrap                                → chat-backend container updated
                                                         → chat-nginx container updated
```

---

## Infrastructure Provisioning

All infrastructure is defined in `terraform/main.tf` and provisioned into `us-east-1`.

### Provider and Region

```hcl
provider "aws" {
  region = "us-east-1"
}
```

The AWS provider is pinned to `~> 5.0` to prevent unexpected behaviour from major version upgrades.

### AMI Selection

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}
```

Rather than hardcoding an AMI ID, Terraform performs a dynamic lookup at apply time against Canonical's official account. This prevents deployment failures caused by deprecated AMI identifiers and ensures the latest stable Ubuntu 22.04 image is always used. The rebuild verification confirmed this correctly provisioned `Ubuntu 22.04.5 LTS` running kernel `6.8.0`.

### EC2 Instance

```hcl
resource "aws_instance" "chat_server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.deployer_key.key_name
  ...
}
```

Instance type is `t3.micro`. The original configuration used `t2.micro`, which triggered an API error on accounts created on or after July 15, 2025, where AWS removed `t2.micro` from the free-tier eligibility matrix. The instance type was updated to `t3.micro` to resolve this. See [Incident: Free-Tier Instance Type](#incident-free-tier-instance-type) below.

The root volume is 15 GB (`gp3`), with `delete_on_termination = true` to avoid orphaned EBS volumes on instance replacement.

### Security Group

```hcl
resource "aws_security_group" "chat_sg" {
  ingress { from_port = 22,  to_port = 22,  protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 80,  to_port = 80,  protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0,   to_port = 0,   protocol = "-1",  cidr_blocks = ["0.0.0.0/0"] }
}
```

Inbound access is restricted to two ports:

| Port | Purpose |
| :--- | :--- |
| 22 / TCP | SSH administrative access |
| 80 / TCP | HTTP — public NGINX entrypoint |

All outbound traffic is permitted so the instance can reach the internet for package installation and Docker image pulls. Port 22 is open to `0.0.0.0/0` for administrative access during this assignment. A production deployment should restrict this to known IP ranges or replace SSH with AWS Systems Manager Session Manager.

Live verification via `aws ec2 describe-security-groups` confirmed both rules are applied and active on the running instance.

### Key Pair

```hcl
resource "aws_key_pair" "deployer_key" {
  key_name   = "chat-assignment-key"
  public_key = file("~/Downloads/chat-assignment-key.pub")
}
```

The public key is uploaded and registered by Terraform. SSH access uses the corresponding private key: `ssh -i ~/Downloads/chat-assignment-key ubuntu@52.70.212.146`.

### Elastic IP

```hcl
resource "aws_eip" "chat_eip" {
  domain = "vpc"
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.chat_server.id
  allocation_id = aws_eip.chat_eip.id
}

output "staging_public_ip" {
  value = aws_eip.chat_eip.public_ip
}
```

The Elastic IP provides a stable public endpoint that does not change when the EC2 instance is replaced. The current allocation is `52.70.212.146`. This was verified during the immutable infrastructure smoke test: after a full `terraform destroy` and `terraform apply` cycle, the same EIP was re-associated with the new instance without any change to the public address.

The `staging_public_ip` output surfaces the IP immediately after `terraform apply` completes.

---

## Server Preparation

The `user_data` block in the EC2 resource definition runs a shell script on first boot. This automates the complete server setup without requiring any manual SSH configuration.

```bash
#!/bin/bash
apt-get update
apt-get install -y docker.io docker-compose
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu
```

What each step does:

| Step | Effect |
| :--- | :--- |
| `apt-get install docker.io docker-compose` | Installs the Docker daemon and Docker Compose |
| `systemctl start docker` | Starts the Docker daemon immediately |
| `systemctl enable docker` | Configures Docker to start automatically on reboot |
| `usermod -aG docker ubuntu` | Adds the `ubuntu` user to the `docker` group — allows running Docker commands without `sudo` |

After provisioning, this was verified by SSHing onto the fresh instance and running `docker ps` without `sudo`. The command succeeded immediately, confirming the bootstrap completed correctly.

**Note:** Git is not installed by this script. The self-hosted GitHub Actions runner installation and the application repository clone at `/home/ubuntu/realtime-chat-app` were performed manually after the instance was provisioned. In a fully automated provisioning pipeline, these steps would be added to `user_data` or an Ansible playbook.

---

## Application Deployment

### Repository Layout on the Host

The application runs from a dedicated directory on the EC2 instance:

```
/home/ubuntu/realtime-chat-app/
├── app/
│   ├── main.py
│   └── requirements.txt
├── frontend/
│   └── index.html
├── Dockerfile
├── docker-compose.yml
└── nginx.conf
```

This directory is decoupled from the GitHub Actions runner's internal workspace (`/home/ubuntu/actions-runner/_work/...`). The runner can be updated or reinstalled without affecting the running application.

### GitHub Actions Workflow

The deployment workflow is defined in `.github/workflows/deploy.yml`:

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

**Trigger:** Any push to the `main` branch.

**Runner:** `runs-on: self-hosted` targets the runner daemon installed on the EC2 instance. Because the runner executes natively on the deployment host, no SSH credentials or external secrets are required.

**Deployment step breakdown:**

| Command | Purpose |
| :--- | :--- |
| `set -e` | Fail-fast — the workflow exits immediately if any command returns a non-zero exit code |
| `cd /home/ubuntu/realtime-chat-app` | Switch to the dedicated deployment directory |
| `git pull` | Pull the latest committed code from the `main` branch |
| `docker-compose up -d --build` | Rebuild any changed images and recreate affected containers in detached mode |
| `docker ps` | Confirm both containers are running after deployment |

`docker-compose up -d --build` is idempotent for containers whose images have not changed — it restarts only the services that were affected by the build.

---

## Container Deployment

### Docker Compose Services

```yaml
services:
  backend:
    build: .
    container_name: chat-backend
    expose:
      - "8000"
    restart: always

  nginx:
    image: nginx:alpine
    container_name: chat-nginx
    ports:
      - "80:80"
    volumes:
      - ./frontend:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - backend
    restart: always
```

**`chat-backend`**
- Built from the local `Dockerfile` using `python:3.11-slim` as the base image
- Uvicorn serves the FastAPI application bound to `0.0.0.0:8000`
- Port 8000 is exposed only on the internal Docker bridge network — it is not published to the host
- `restart: always` ensures automatic recovery if the process exits unexpectedly

**`chat-nginx`**
- Uses the official `nginx:alpine` image
- Publishes Port 80 to the host: `0.0.0.0:80->80/tcp`
- Mounts `./frontend` into `/usr/share/nginx/html` (read-only) to serve static files
- Mounts `./nginx.conf` into `/etc/nginx/nginx.conf` (read-only) to apply the custom routing configuration
- `depends_on: backend` ensures the backend service starts before NGINX

**Docker network:** Both containers are placed on a Compose-managed bridge network (`realtime-chat-app_default`). Docker's embedded DNS allows NGINX to resolve the backend by service name.

### NGINX Routing

```nginx
server {
    listen 80;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location /ws {
        proxy_pass http://backend:8000/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
```

| Route | Behaviour |
| :--- | :--- |
| `GET /` | Serves `index.html` from the mounted `frontend/` directory |
| `GET /ws` | Proxies to `backend:8000/ws` with WebSocket upgrade headers |

The `proxy_pass` directive uses the Docker service name `backend` rather than `localhost` or a hardcoded IP. Docker's internal DNS resolves this to the backend container's bridge IP at runtime.

---

## Incident: Free-Tier Instance Type

During the initial `terraform apply`, the EC2 provisioning step failed with:

```
Error: creating EC2 Instance: operation error EC2: RunInstances...
api error InvalidParameterCombination: The specified instance type is not eligible for Free Tier.
```

**Root cause:** AWS accounts created on or after July 15, 2025, no longer include `t2.micro` in the free-tier eligibility matrix. The instance type was updated from `t2.micro` to `t3.micro` in `main.tf`, which resolved the error and kept the deployment within the free-tier cost boundary.

---

## Immutable Infrastructure Smoke Test

To validate that the Terraform configuration could recreate the environment from zero, the full infrastructure stack was intentionally destroyed and rebuilt.

**Sequence:**

```bash
terraform destroy
terraform apply
```

**Observations:**

1. The rebuilt instance was assigned a new internal ED25519 host key. The first SSH attempt produced a host fingerprint mismatch warning due to the cached key in `~/.ssh/known_hosts`. The stale entry was cleared with:
   ```bash
   ssh-keygen -R 52.70.212.146
   ```

2. After clearing the cache, SSH access was confirmed on the new instance:
   ```
   Welcome to Ubuntu 22.04.5 LTS (GNU/Linux 6.8.0-1061-aws x86_64)
   ubuntu@ip-172-31-22-67:~$ docker ps
   CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES
   ```

3. `docker ps` succeeded without `sudo`, confirming the `user_data` bootstrap completed correctly on the new instance.

4. The Elastic IP `52.70.212.146` was re-associated with the new instance automatically by Terraform. The public endpoint did not change.

---

## Deployment Verification

The following verification activities were performed after deployment to confirm each layer of the stack was operating correctly.

| Verification | Command / Method | Confirmed |
| :--- | :--- | :--- |
| Infrastructure state | `terraform plan` | Output: `No changes. Infrastructure matches configuration.` Zero drift. |
| EC2 reachability | `ssh -i ~/Downloads/chat-assignment-key ubuntu@52.70.212.146` | SSH session established successfully |
| Container status | `docker ps` on EC2 | `chat-backend` and `chat-nginx` both in `Up` state |
| Port 80 listening | `ss -tlnp` on EC2 | Port 80 listening on `0.0.0.0` and `[::]` |
| Host firewall | `sudo ufw status` on EC2 | `inactive` — no host-level firewall blocking traffic |
| HTTP response (localhost) | `curl http://localhost` on EC2 | HTTP 200 — full HTML response returned |
| HTTP response (private IP) | `curl http://172.31.22.67` on EC2 | HTTP 200 |
| HTTP response (public IP) | `curl http://52.70.212.146` from external host | HTTP 200 — application accessible externally |
| WebSocket handshake | `curl` with `Upgrade: websocket` headers to `/ws` | HTTP 101 Switching Protocols — upgrade accepted |
| NGINX access log | `docker logs chat-nginx` | GET requests logged with 200; WebSocket connections logged with 101 |
| Backend log | `docker logs chat-backend` | `Uvicorn running on http://0.0.0.0:8000`; WebSocket connections accepted |
| Multi-user broadcast | Two browser tabs at `http://52.70.212.146` | Messages sent from one tab appeared immediately in the other |
| GitHub Actions | Push to `main`, workflow log reviewed | Runner accepted job; deployment steps completed; `docker ps` confirmed both containers running |

---

## Deployment Outcome

| Component | Status | Evidence |
| :--- | :--- | :--- |
| EC2 instance | Provisioned and running | SSH access confirmed; `t3.micro`, Ubuntu 22.04 |
| Elastic IP | Allocated and associated | `52.70.212.146` reachable; persists across instance replacement |
| Security Group | Enforced | Ports 22 and 80 confirmed open via live AWS CLI verification |
| Docker daemon | Running | `docker ps` executes without `sudo`; containers healthy |
| `chat-backend` | Running | Uvicorn bound to `0.0.0.0:8000`; WebSocket endpoint responding |
| `chat-nginx` | Running | Serving frontend at `/`; proxying WebSocket traffic at `/ws` |
| NGINX routing | Correct | HTTP 200 on `/`; HTTP 101 on `/ws` from external host |
| WebSocket communication | Operational | Real-time message broadcast confirmed across multiple browser tabs |
| GitHub Actions pipeline | Functional | Automated deployment triggered on push to `main`; containers updated without manual intervention |
| Terraform state | Consistent | `terraform plan` reports no drift against live AWS infrastructure |
