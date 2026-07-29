# Troubleshooting & Bug Resolution Guide

This document records the significant implementation issues encountered during this project. For each issue it describes the observed symptoms, the investigation process, the root cause, the resolution applied, how the fix was verified, and the engineering lesson taken away. The objective is to provide an accurate record that supports future debugging and serves as a reference for similar deployments.

**Related documents:**
- [README.md](./README.md) — Project overview, architecture, engineering decisions, and production considerations
- [CloudDeployment.md](./CloudDeployment.md) — Infrastructure provisioning, server preparation, and deployment verification
- [GitHubActions.md](./GitHubActions.md) — CI/CD pipeline design, runner configuration, and deployment automation

---

## Incident 1 — Backend Container Unreachable from NGINX

### Summary

The FastAPI backend container started successfully but was unreachable from the NGINX container and from the host. No traffic could reach the application even after the container was confirmed running.

### Symptoms

- `docker-compose up -d --build` completed without errors.
- `docker ps` showed `chat-backend` in the `Up` state.
- HTTP requests to the application returned no response or a connection refused error.
- The backend was inaccessible even when port mapping was confirmed in the Compose file.

### Investigation

Inspection of the `Dockerfile` `CMD` instruction revealed the Uvicorn process binding argument:

```dockerfile
CMD ["uvicorn", "main:app", "--host", "127.0.0.1", "--port", "8000"]
```

Inside an isolated Docker container, `127.0.0.1` is the container's own loopback interface. A process bound to this address accepts connections only from within the same container. Any traffic arriving from outside the container — including from the NGINX container on the Docker bridge network — is dropped at the network layer before reaching the process.

### Root Cause

Uvicorn was bound to `127.0.0.1` (loopback only). Docker containers each have their own network namespace. The loopback interface inside `chat-backend` is not reachable from `chat-nginx` or from the host, regardless of port mappings declared in `docker-compose.yml`.

### Resolution

Updated the `CMD` instruction in `Dockerfile` to bind on all interfaces:

```dockerfile
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Binding to `0.0.0.0` instructs Uvicorn to accept connections on all available network interfaces inside the container, including the Docker bridge interface through which NGINX communicates.

### Verification

After rebuilding with `docker-compose up -d --build`:
- `curl http://localhost` on the host returned an HTTP 200 response.
- The NGINX access log showed successful requests being proxied to the backend.
- The backend log confirmed: `Uvicorn running on http://0.0.0.0:8000`.

### Lessons Learned

Binding a process to `127.0.0.1` inside a container is a container-local loopback, not the host loopback. Services that need to receive traffic from other containers or from the host must bind to `0.0.0.0`. This is a common source of silent failure because the container appears healthy while being entirely unreachable.

---

## Incident 2 — NGINX Serving Default Page Instead of Application

### Summary

After starting the stack, navigating to `http://localhost` displayed the default NGINX welcome page rather than the chat application frontend.

### Symptoms

- `docker ps` confirmed both containers were running.
- Browser access to `http://localhost` returned the NGINX default page: "Welcome to nginx!"
- No 404 or 500 error — NGINX was serving its own default content.
- The `frontend/index.html` file existed on the host.

### Investigation

Reviewed the `docker-compose.yml` volume configuration for the `nginx` service. The volume mount responsible for making the frontend directory available inside the container was commented out:

```yaml
nginx:
  image: nginx:alpine
  ports:
    - "80:80"
  volumes:
    # - ./frontend:/usr/share/nginx/html:ro   ← commented out
    - ./nginx.conf:/etc/nginx/nginx.conf:ro
```

Without this mount, the NGINX container had no access to the `frontend/` directory. Its document root (`/usr/share/nginx/html`) contained only the default NGINX placeholder files, which it served instead.

### Root Cause

The volume mount mapping `./frontend` on the host to `/usr/share/nginx/html` inside the container was commented out in `docker-compose.yml`. NGINX served its own bundled default content because no application files were present at the configured document root.

### Resolution

Uncommented the volume mount:

```yaml
volumes:
  - ./frontend:/usr/share/nginx/html:ro
  - ./nginx.conf:/etc/nginx/nginx.conf:ro
```

The `:ro` flag mounts the directory as read-only, which is appropriate for static assets that the container should serve but not modify.

### Verification

After restarting the stack:
- `http://localhost` loaded the chat application UI.
- The NGINX access log showed `GET / HTTP/1.1" 200` with the correct content length matching `index.html`.

### Lessons Learned

A commented-out volume mount in a Compose file produces no error — the container starts normally and serves whatever happens to be at the default path. When static content is missing or replaced by defaults, verify volume mount declarations before investigating the application or NGINX configuration.

---

## Incident 3 — WebSocket Connections Failing After UI Loaded

### Summary

The chat application UI loaded correctly but the WebSocket connection failed immediately and continuously. The chat feature was non-functional despite the frontend rendering successfully.

### Symptoms

- `http://localhost` served the frontend with HTTP 200.
- The connection status indicator in the UI showed "Disconnected" immediately on page load.
- Browser DevTools Network panel showed the `/ws` WebSocket connection failing to establish.
- Reloading the page produced the same result.

### Investigation

This incident had two separate root causes in `nginx.conf`, both identified by inspecting the `/ws` location block.

**Cause A — Incorrect upstream address:**

```nginx
location /ws {
    proxy_pass http://localhost:8000/ws;   ← points to NGINX's own loopback
    ...
}
```

Inside the NGINX container, `localhost` resolves to the container's own loopback interface (`127.0.0.1`), not to the backend container. There is no process listening on port 8000 inside the NGINX container, so every WebSocket connection attempt was immediately refused at the proxy layer.

**Cause B — WebSocket upgrade headers commented out:**

```nginx
location /ws {
    proxy_pass http://backend:8000/ws;
    proxy_http_version 1.1;
    # proxy_set_header Upgrade $http_upgrade;     ← commented out
    # proxy_set_header Connection "upgrade";       ← commented out
    ...
}
```

HTTP/1.1 WebSocket upgrades require the `Upgrade` and `Connection` headers to be forwarded through the proxy. Without these headers, NGINX treats the connection as a standard HTTP request. The backend receives no upgrade signal and the WebSocket handshake fails at the protocol level.

### Root Cause

Two compounding faults in `nginx.conf`:

1. `proxy_pass` pointed to `http://localhost:8000/ws`. Inside the NGINX container, `localhost` is the container's own loopback — not the backend service. Docker's embedded DNS provides service name resolution; the correct upstream address is `http://backend:8000/ws`.

2. The `Upgrade` and `Connection` headers were commented out, preventing NGINX from forwarding the WebSocket upgrade handshake to the backend.

Either fault alone would have caused the symptom. Both needed to be resolved.

### Resolution

Updated `nginx.conf` with two changes:

```nginx
location /ws {
    proxy_pass http://backend:8000/ws;        # changed: localhost → backend
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;   # uncommented
    proxy_set_header Connection "upgrade";    # uncommented
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
}
```

### Verification

After applying the fix and restarting the stack:
- Browser DevTools showed the `/ws` connection completing with HTTP 101 Switching Protocols.
- The UI connection status changed to "Connected".
- A message sent from one browser tab appeared immediately in a second tab open to the same URL.
- The backend log confirmed: `WebSocket /ws [accepted]` and `connection open`.

### Lessons Learned

Within a Docker network, container-to-container communication uses Docker's internal DNS. Service names defined in `docker-compose.yml` are the correct upstream addresses in NGINX proxy directives — not `localhost`, not `127.0.0.1`, and not hardcoded IPs. WebSocket proxying additionally requires explicit `Upgrade` and `Connection` header forwarding; standard HTTP proxy configuration is insufficient.

---

## Incident 4 — EC2 Instance Type Not Eligible for Free Tier

### Summary

`terraform apply` passed static validation but failed during the EC2 API call with an instance type eligibility error, preventing infrastructure provisioning.

### Symptoms

```
Error: creating EC2 Instance: operation error EC2: RunInstances...
api error InvalidParameterCombination: The specified instance type is not eligible for Free Tier.
```

The Terraform plan succeeded with no warnings. The error only appeared during `terraform apply` when AWS validated the request against the account's free-tier eligibility rules.

### Investigation

The original `main.tf` declared:

```hcl
instance_type = "t2.micro"
```

AWS free-tier eligibility is governed by account creation date cohort, not by region or instance family alone. For accounts created on or after July 15, 2025, AWS removed `t2.micro` from the free-tier eligibility matrix. The updated baseline for these accounts is `t3.micro`. Because Terraform's plan phase performs only local validation against the provider schema, this constraint is not detectable until the API call is made.

### Root Cause

The `t2.micro` instance type is not eligible for the free tier on AWS accounts created on or after July 15, 2025. The AWS API rejected the `RunInstances` request with a parameter combination error.

### Resolution

Updated `instance_type` in `terraform/main.tf`:

```hcl
instance_type = "t3.micro"
```

`t3.micro` is the current free-tier eligible baseline for modern AWS accounts and is in the same cost tier.

### Verification

Re-ran `terraform apply`. The EC2 instance provisioned successfully. SSH access to the instance confirmed it was running Ubuntu 22.04 on the correct instance type.

### Lessons Learned

`terraform plan` validates configuration syntax and provider schema but does not make API calls. Account-level eligibility constraints, IAM permission boundaries, and service quotas are only evaluated at apply time. When `terraform plan` succeeds but `terraform apply` fails, the error is in the interaction between the declared configuration and the live account state, not in the Terraform code itself.

---

## Incident 5 — SSH Host Fingerprint Mismatch After Instance Replacement

### Summary

After destroying and rebuilding the EC2 instance using Terraform, SSH connections to the Elastic IP were blocked by a host verification failure on the local machine.

### Symptoms

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
...
Host key verification failed.
```

The Elastic IP address was unchanged (`52.70.212.146`), but SSH refused to connect.

### Investigation

The local `~/.ssh/known_hosts` file stores a fingerprint for each host address that has been connected to previously. When Terraform destroyed and rebuilt the EC2 instance, the new instance was provisioned from a fresh OS image with a newly generated ED25519 host key. The new host key did not match the fingerprint stored against `52.70.212.146` in `known_hosts`. SSH correctly treated this as a potential man-in-the-middle condition and refused to continue.

This is expected behaviour when an immutable infrastructure approach replaces a host at a stable IP address.

### Root Cause

`terraform destroy` followed by `terraform apply` provisioned a new EC2 instance at the same Elastic IP. The new instance generated a fresh ED25519 host key on first boot. The local SSH client's cached fingerprint for `52.70.212.146` no longer matched the live host key.

### Resolution

Removed the stale fingerprint from the local known hosts cache:

```bash
ssh-keygen -R 52.70.212.146
```

On the subsequent SSH attempt, the client prompted to accept and store the new fingerprint:

```
The authenticity of host '52.70.212.146 (52.70.212.146)' can't be established.
ED25519 key fingerprint is SHA256:BhXDKapO/1bRM4w2XkJ8wG3quDjeg2K40YwyfCK/5ts.
Are you sure you want to continue connecting (yes/no)?
```

After accepting, the session connected successfully:

```
Welcome to Ubuntu 22.04.5 LTS (GNU/Linux 6.8.0-1061-aws x86_64)
ubuntu@ip-172-31-22-67:~$
```

### Verification

SSH session established. `docker ps` executed without `sudo`, confirming the `user_data` bootstrap had also completed correctly on the new instance.

### Lessons Learned

When immutable infrastructure replaces a host at a stable address, cached SSH fingerprints on client machines become invalid. This is not an error — it is the SSH client behaving correctly. The resolution is always to clear the stale cache entry with `ssh-keygen -R <address>` rather than disabling host key verification with `StrictHostKeyChecking=no`, which would undermine the security control that produces the warning.

---

## Incident 6 — GitHub-hosted Runner Unavailable

### Summary

The initial GitHub Actions workflow configuration using `runs-on: ubuntu-latest` failed to execute. No runner was allocated and deployment jobs remained queued indefinitely.

### Symptoms

- GitHub Actions workflow was correctly triggered on push to `main`.
- The job entered a queued state and never progressed to execution.
- No error message was produced — the job simply waited without being picked up.
- Workflow syntax was valid; the issue was not in the configuration file.

### Investigation

GitHub-hosted runners (`runs-on: ubuntu-latest`) are provisioned by GitHub on demand. On this account, runner allocation failed due to account-level billing restrictions that prevented GitHub from provisioning ephemeral hosted execution environments. The restriction was at the account tier level, not at the repository or workflow configuration level.

This was confirmed by reviewing the Actions tab, which showed the job as queued with no runner accepting it, and by checking the account billing status.

### Root Cause

The GitHub account did not have access to GitHub-hosted runners due to billing tier restrictions. Workflow syntax was correct; the failure was in the platform-level runner allocation step before any workflow steps executed.

### Resolution

Installed a self-hosted GitHub Actions runner directly on the EC2 instance. The workflow's `runs-on` directive was changed from `ubuntu-latest` to `self-hosted`:

```yaml
jobs:
  deploy:
    runs-on: self-hosted   # changed from ubuntu-latest
```

The self-hosted runner daemon runs as the `ubuntu` user on the EC2 instance and picks up jobs as soon as they are queued by GitHub.

### Verification

On the next push to `main`, the job was picked up immediately by the self-hosted runner. The Actions log confirmed execution under the `ubuntu` identity at the expected working directory on EC2. All subsequent workflow steps completed successfully.

### Lessons Learned

GitHub-hosted runner availability depends on the account's billing tier. In environments where hosted runners are unavailable, self-hosted runners are a fully supported alternative that preserves the same workflow event model. When a workflow is correctly configured but jobs remain permanently queued, the likely cause is runner availability rather than workflow syntax. For this deployment pattern, the self-hosted runner on EC2 provides the additional benefit of eliminating the SSH hop required when a hosted runner deploys to a remote instance.

---

## Investigation Techniques

The following commands were used during debugging and verification throughout the project. Each addresses a different layer of the stack.

| Command | Layer | What it verifies |
| :--- | :--- | :--- |
| `docker ps` | Container | Which containers are running; their uptime, published ports, and names |
| `docker logs <container>` | Container | Process startup output, runtime errors, and access logs |
| `docker exec <container> <cmd>` | Container | Execute a command inside a running container to inspect its internal state |
| `curl http://localhost` | Application | Whether NGINX is serving a response on the host loopback |
| `curl http://<private-ip>` | Network | Whether port binding is accepting connections on the host network interface |
| `curl http://<public-ip>` | Network | Whether the application is reachable externally via the Elastic IP |
| `curl -H "Upgrade: websocket" ...` | WebSocket | Whether the NGINX proxy correctly returns HTTP 101 for WebSocket upgrade requests |
| `ss -tlnp` | OS networking | Which ports are listening and on which interfaces |
| `sudo ufw status` | OS firewall | Whether a host-level firewall is active and blocking traffic |
| `sudo iptables -L -n -v` | OS networking | Raw iptables rules including Docker's NAT and forwarding entries |
| `ssh -i <key> ubuntu@<ip>` | Infrastructure | Whether the EC2 instance is reachable and the key pair is correctly configured |
| `ssh-keygen -R <ip>` | SSH client | Clear a stale host fingerprint from known_hosts after instance replacement |
| `terraform plan` | Infrastructure | Whether the live AWS state matches the Terraform configuration; surface any drift |
| `aws ec2 describe-security-groups` | Infrastructure | Live inbound and outbound rules on the Security Group attached to the instance |
| `aws ec2 describe-instances` | Infrastructure | Live instance state, attached Security Groups, subnet, VPC, and public IP |
| GitHub Actions log | CI/CD | Step-by-step execution output; runner identity; failure point on non-zero exit |

---

## Common Troubleshooting Checklist

Use this checklist when diagnosing a deployment issue. Work from the infrastructure layer down to the application layer to isolate the failure point before investigating code.

### Infrastructure

- [ ] EC2 instance is in the `running` state (`aws ec2 describe-instances`)
- [ ] Elastic IP is associated with the correct instance (`aws ec2 describe-addresses`)
- [ ] Security Group has inbound rules for Port 22 and Port 80 (`aws ec2 describe-security-groups`)
- [ ] Route table has a `0.0.0.0/0` route to an Internet Gateway
- [ ] Network ACL has no DENY rule blocking Port 80 or Port 22
- [ ] `terraform plan` reports no drift

### OS and Host Networking

- [ ] Port 80 is listening on `0.0.0.0` (`ss -tlnp`)
- [ ] UFW is inactive or has an allow rule for Port 80 (`sudo ufw status`)
- [ ] Docker daemon is running (`systemctl status docker`)
- [ ] `ubuntu` user can run `docker` without `sudo`

### Containers

- [ ] Both `chat-backend` and `chat-nginx` are in the `Up` state (`docker ps`)
- [ ] NGINX container has the correct volume mounts (frontend directory and nginx.conf)
- [ ] Backend port 8000 is not published to the host (it should only be `expose`d, not `ports`)
- [ ] No unexpected errors in `docker logs chat-backend` or `docker logs chat-nginx`

### Network and Reverse Proxy

- [ ] `curl http://localhost` returns HTTP 200 from within the EC2 instance
- [ ] `curl http://<private-ip>` returns HTTP 200
- [ ] `curl http://<public-ip>` returns HTTP 200 from an external host
- [ ] NGINX `proxy_pass` uses the Docker service name (`backend`), not `localhost`
- [ ] WebSocket `Upgrade` and `Connection` headers are present and uncommented in `nginx.conf`
- [ ] WebSocket endpoint returns HTTP 101 when tested with upgrade headers

### CI/CD

- [ ] Self-hosted runner daemon is running on the EC2 instance
- [ ] GitHub Actions job is picked up immediately after a push (not remaining queued)
- [ ] Deployment step navigates to `/home/ubuntu/realtime-chat-app` before running `git pull`
- [ ] Both containers are in `Up` state in the `docker ps` output at the end of the workflow

---

## Key Engineering Lessons

**Verify assumptions with live evidence, not with configuration files.**
A Terraform file, a Compose file, or an nginx.conf that declares the correct configuration is not proof that the running environment matches. During the production investigation, every layer was verified against the live state using AWS CLI and SSH commands. The configuration turned out to be correct, but that conclusion was reached through evidence, not assumption.

**Distinguish between layers before investigating code.**
`ERR_TIMED_OUT` in a browser, a container that starts but is unreachable, and a WebSocket that immediately disconnects all look similar from the outside. Each has a different cause at a different layer. Identifying the correct layer first — infrastructure, OS networking, Docker, NGINX, or application — prevents spending time debugging the wrong component. The `127.0.0.1` binding issue (Incident 1) and the `localhost` proxy_pass issue (Incident 3) produced similar symptoms for different reasons at different layers.

**Validate deployment commands manually before automating them.**
The GitHub Actions deployment sequence (`git pull` and `docker-compose up -d --build`) was run manually on the EC2 instance and confirmed working before it was embedded in the workflow. When the automated pipeline ran, any failure could be attributed to the automation layer rather than the commands. This significantly reduces the search space when debugging CI/CD failures.

**Incremental verification catches problems early and narrows scope.**
The CI/CD pipeline was built in stages: runner provisioning was verified before deployment commands were added; deployment commands were verified manually before being automated. Each stage produced a known-good baseline that the next stage could build on. This approach meant that when something did fail, the scope of investigation was limited to the most recently added layer.

**Expected warnings can indicate correct behaviour.**
The SSH fingerprint mismatch warning (Incident 5) was not a malfunction — it was the SSH client correctly detecting that the host identity had changed after an infrastructure rebuild. Treating it as a configuration error would have been incorrect. Understanding what a warning or error is actually reporting prevents unnecessary changes to working systems.

---

## Summary

The issues encountered during this project were resolved through structured investigation: observing the symptom, identifying the layer responsible, finding the specific misconfiguration, applying a targeted fix, and confirming the fix through repeatable verification. Most failures were silent — containers that appeared healthy, processes that started without errors, and configurations that passed static validation — which required active verification at each layer rather than waiting for an obvious error message. Systematic, evidence-based debugging was more effective than attempting to reason about the system from configuration files alone.
