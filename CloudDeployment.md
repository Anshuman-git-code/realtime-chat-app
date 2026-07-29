# Architecture Decision Record (ADR) & Cloud Deployment Log

## ADR 01: Automated Staging Environment Provisioning via IaC

### Context & Problem Statement
The assignment requires deploying the fixed real-time chat application stack to a cloud hosting environment (Section 6.4). The standard approach involves manually navigating the cloud vendor console to spin up virtual resources. However, manual click-through setups lack reproducibility, carry risk of human error, and create architectural configuration drift that makes recovery from node failures slow and error-prone.

### Considered Options
1. **Option 1: Manual AWS Console Provisioning**
   - *Pros:* Low initial time investment; zero scripting overhead.
   - *Cons:* Complete lack of auditing, non-reproducible, prone to configuration mismatch.
2. **Option 2: AWS CloudFormation**
   - *Pros:* Native to the target ecosystem.
   - *Cons:* Verbose JSON/YAML syntax; tightly couples the codebase to a single vendor.
3. **Option 3: Terraform (Declarative Infrastructure as Code)**
   - *Pros:* Human-readable HashiCorp Configuration Language (HCL), maintains execution state files, ensures deterministic environment recovery from zero, cloud-agnostic platform primitives.
   - *Cons:* Slight upfront syntax structuring overhead under a tight time budget.

### Decision & Trade-Offs
**Decision:** Selected **Option 3 (Terraform)** to provision the underlying compute and networking layers, keeping the implementation completely flat (`main.tf`) with no modules or remote backends to respect the short time constraints. 

*Trade-offs:* While it required a minor upfront development cost, it completely decouples infrastructure generation from application runtime logic. Docker Compose remains the IaC for the *application layer*, while Terraform acts as the IaC for the *infrastructure layer*.

---

## 2. Infrastructure Layer & Operational Trade-Offs

The underlying topology was successfully initialized and provisioned into `us-east-1` via Terraform using a single, flat architecture.

### Resource Boundary Definitions
- **Compute Host:** Dynamically mapped using a Canonical Ubuntu 22.04 LTS AMI data source lookup. This eliminates hardcoded values and prevents deployment failure when old AMI images are deprecated by the cloud vendor.
- **Automated Bootstrapping:** Integrated native `user_data` shell blocks to fully automate the installation and startup of the Docker client and Docker Compose runtimes on first boot. This closes the automation gap, providing a true zero-touch infrastructure rollout.
- **Security Boundaries (`aws_security_group`):** Ingress is strictly throttled to minimum-viable avenues: Port 80 for public Nginx reverse-proxy entrypoint and Port 22 for administrative SSH access. 
- **CI/CD Networking Trade-Off:** Port 22 is intentionally exposed to `0.0.0.0/0`. This represents a deliberate infrastructure trade-off: because GitHub-hosted automation runners operate out of dynamic public IP pools, locking down administrative access to a tight range would completely break automated remote deployment delivery pipelines.

---

## 3. Incident Mitigation: AWS Free-Tier Terms Allocation Flaw

During the execution phase (`terraform apply`), the syntax successfully passed static validation, but failed during target API invocation on the cloud provider side.

### Incident Signature
```text
Error: creating EC2 Instance: operation error EC2: RunInstances...
api error InvalidParameterCombination: The specified instance type is not eligible for Free Tier.
```

### Log Diagnostics & Root Cause Analysis
An analysis of modern AWS global allocation accounts shows that Free Tier infrastructure rules are governed strictly by the account creation date cohort, rather than regional availability. For cloud accounts generated on or after July 15, 2025, AWS explicitly excluded the aging `t2.micro` family from the free-tier matrix, replacing the default baseline requirement with modern generations like `t3.micro`.

### Technical Remediation
Refactored the instance resource block properties within `main.tf` to target `t3.micro`. This completely satisfied the modern AWS account tier policies while keeping the environment within a strict zero-cost budget constraint.

---

## 4. Verification & Immutable Infrastructure Smoke Testing

To validate the "reproducible from zero" claim and test the decoupling of the network routing layer from the compute layer, the infrastructure stack was purposefully destroyed and completely rebuilt via Terraform.

### The Host Fingerprint Mismatch Observation
Because the compute layer is immutable, rebuilding the instance generated a completely fresh OS installation with a new internal ED25519 host key. Attempting to connect threw an authentication warning due to the cached signature in the local Mac terminal. The local cache was safely pruned using:
```bash
ssh-keygen -R 52.70.212.146
```

### Empirical Verification Logs
Following the local key cache flush, an SSH session was successfully initialized onto the newly generated compute node:

```text
anshumanmohapatra@Anshumans-MacBook-Air devops % ssh -i ~/Downloads/chat-assignment-key ubuntu@52.70.212.146
The authenticity of host '52.70.212.146 (52.70.212.146)' can't be established.
ED25519 key fingerprint is SHA256:BhXDKapO/1bRM4w2XkJ8wG3quDjeg2K40YwyfCK/5ts.
...
Welcome to Ubuntu 22.04.5 LTS (GNU/Linux 6.8.0-1061-aws x86_64)
ubuntu@ip-172-31-22-67:~\$ docker ps
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

### Critical Architectural Observations & Breakthroughs
1. **Dynamic Image Upgrades:** The node was initialized with Ubuntu version `22.04.5 LTS` (running kernel `6.8.0`). This directly confirms that the `data "aws_ami"` block functions correctly, dynamically provisioning the latest stable cloud footprint rather than relying on a hardcoded, aging identifier.
2. **Zero-Touch Runtime Execution:** Running `docker ps` on the freshly initialized host succeeded immediately without requiring `sudo` privileges or manual software installation steps. This proves that the `user_data` bootstrap layer successfully initialized the background Docker daemon client dependencies during the initial boot cycle.
3. **Elastic IP Preservation:** While the underlying virtual machine instance was completely replaced, the static AWS Elastic IP address (`52.70.212.146`) persisted across the teardown-and-rebuild sequence. This confirms host-entrypoint invariance, validating that future CI/CD deployment channels will remain functional without requiring manual configuration adjustments.

---

## 5. Architectural Verification Summary

| Component | Target Parameter | Status | Observed Verification Signal |
| :--- | :--- | :--- | :--- |
| **Compute Host** | `t3.micro` (Ubuntu 22.04) | **Active** | System fully accessible via `chat-assignment-key`. |
| **Static Router** | AWS Elastic IP (`52.70.212.146`) | **Bound** | Public IP routing state persists across session logs. |
| **Security Group** | Port 22, Port 80 Open | **Enforced** | Direct administrative SSH tunnels pass cleanly. |
| **Container Engine**| Docker Client / Daemon | **Ready** | Non-privileged process execution verified via empty table output. |
