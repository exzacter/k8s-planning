# Alternate Suggestions & Additions

Independent analysis of the planned architecture — what I would change, what I would add, and what is worth questioning. Each item includes trade-offs so you can make informed decisions rather than just accepting or rejecting the suggestion.

This document does not replace PLAN.md or EXECUTION_PLAN.md. It sits alongside them as a "what if" reference.

---

## Section 1: Architectural Changes

---

### 1.1 Replace AlertManager → GitHub Actions Scaling with Cluster Autoscaler

**What the current plan does:**
AlertManager detects resource pressure → fires webhook → webhook adapter → GitHub repository_dispatch → GitHub Actions runner wakes up → Terraform + Ansible provision a new VM → node joins cluster.

**The problem:**
This chain has significant latency. GitHub Actions has a cold-start delay of 30–90 seconds before a job even begins. Add AlertManager's 5-minute evaluation window, Terraform provisioning time (~60–90 seconds for a VM clone), Ansible configuration (~3–5 minutes), and kubeadm join (~2 minutes) — a scale-out event from trigger to Ready node takes **10–15 minutes minimum**.

There is also a chain of failure points: if the runner is down, if GitHub's API is degraded, if the webhook adapter crashes — the scaling system is silent.

**The alternative: Kubernetes Cluster Autoscaler**
The Cluster Autoscaler watches for pods stuck in `Pending` state because no node has capacity, then calls the cloud provider API to add a node. This is how EKS, GKE, and AKS autoscaling works. The signal is pod scheduling pressure, not a resource percentage.

For Proxmox, there is a community Cluster Autoscaler cloud provider implementation:
- https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- Proxmox cloud provider: https://github.com/sergelogvinov/proxmox-cloud-controller-manager

**Pros:**
- Kubernetes-native — this is exactly how AWS SysEng teams work with EKS autoscaling
- No AlertManager → GitHub → Actions chain — scaling decisions happen inside the cluster
- Responds to actual scheduling pressure, not a metric threshold you need to tune
- Direct CKA/AWS parallel (Cluster Autoscaler is a CKA topic)
- The deploy and remove GitHub Actions workflows collapse to one operator

**Cons:**
- Proxmox cloud provider is community-maintained, not officially supported
- Less fine-grained control over which Proxmox node a VM lands on
- Removes the GitHub Actions learning element
- You lose the explicit "resize vertically first" logic — Cluster Autoscaler only adds nodes
- More complex to bootstrap

**Hybrid recommendation:**
Keep the GitHub Actions workflows for the resize (vertical scaling) path — that genuinely needs custom logic. Use Cluster Autoscaler for horizontal scale-out and scale-in.

---

### 1.2 OpenTofu + MinIO Instead of Terraform Cloud

**What the current plan does:**
Start with Terraform Cloud for state, migrate to MinIO later.

**The concern:**
HashiCorp changed Terraform's license from MPL to BSL in August 2023. The community forked it as **OpenTofu** under the Linux Foundation, which is API-compatible and under the original MPL license.

**The alternative:**
Use **OpenTofu** from the start with **MinIO** on Proxmox as the S3-compatible state backend.

- OpenTofu is a drop-in replacement — same HCL syntax, same provider ecosystem, same `bpg/proxmox` provider works without modification
- MinIO runs as a standalone VM on Proxmox (not inside k8s — pre-cluster, always available)
- The S3 backend config in OpenTofu is identical to what you would write for AWS S3 — maximum AWS learning parallel

**Pros:**
- Fully open source, no license concerns
- No Terraform Cloud account or token — fewer external dependencies
- MinIO S3 backend = identical config to real AWS S3 backend (muscle memory for AWS work)
- State lives on your LAN — no external service dependency for CI/CD

**Cons:**
- OpenTofu is newer — slightly less StackOverflow/blog coverage than Terraform (catching up fast)
- MinIO must exist before any Terraform/OpenTofu runs — needs its own VM or Proxmox host install
- Some enterprise tooling still references "Terraform" specifically

**MinIO reference:** https://min.io/docs/minio/linux/index.html
**OpenTofu:** https://opentofu.org/docs/

---

### 1.3 Actions Runner Controller Instead of a Static Runner VM

**What the current plan does:**
A dedicated VM on Proxmox runs the GitHub Actions self-hosted runner as a persistent service.

**The problem:**
This VM is a single point of failure. If it goes down, no workflows can run — including emergency scale-out events. It also consumes resources 24/7 when it is idle most of the time.

**The alternative: Actions Runner Controller (ARC)**
ARC is a Kubernetes operator that runs GitHub Actions runners as pods inside the cluster itself:
- Ephemeral runners: each job gets a fresh pod, destroyed after the job completes
- Autoscaling: ARC scales runner pod count based on the GitHub Actions job queue — zero runners when idle
- Managed by ArgoCD like everything else

The cluster that the runners manage also runs the runners. Once bootstrapped, deploy ARC via ArgoCD and the static runner VM is no longer needed (keep it only for the bootstrap workflow itself).

**Pros:**
- No single point of failure — runner pods can be rescheduled on any worker node
- Ephemeral runners — each job starts clean
- Zero resource consumption when idle
- Managed by ArgoCD — runner config changes are Git commits

**Cons:**
- Chicken-and-egg: ARC runs inside the cluster, but you need a runner to bootstrap the cluster. The static VM is still required for bootstrap.
- Slightly more complex setup (ARC operator + RunnerDeployment CRDs)
- Runners run as pods — Kubernetes-level isolation, not VM-level isolation

**Reference:** https://github.com/actions/actions-runner-controller

---

## Section 2: Additions to the Project

---

### 2.1 External Secrets Operator + Vault

**What is missing:**
Secrets management in the current plan has several weaknesses:
- The kubeconfig in GitHub Secrets grants full cluster-admin to anyone who can access the repo settings
- The Proxmox API token can create and destroy VMs — if leaked, it is dangerous
- The webhook adapter's GitHub PAT is stored in a k8s Secret, which in etcd is base64-encoded (not encrypted at rest by default)
- No secret rotation mechanism

**What External Secrets Operator + Vault does:**
- **HashiCorp Vault** (deployed on Proxmox, outside k8s) stores all secrets with encryption, access policies, and audit logging
- **External Secrets Operator** is a k8s operator that reads secrets from Vault and syncs them into k8s Secrets automatically
- Vault can issue short-lived dynamic credentials (e.g. a Proxmox token that expires in 1 hour, used for one Terraform run)

**AWS parallel:** This is exactly how AWS Secrets Manager + External Secrets Operator works on EKS. A very commonly asked about pattern in AWS SysEng interviews.

**Pros:**
- Secrets are encrypted at rest
- Audit log of every secret access
- Secret rotation without redeploying k8s resources
- Direct AWS Secrets Manager learning parallel

**Cons:**
- Vault is significant additional infrastructure (needs its own VM)
- Vault unsealing after reboot requires manual intervention or auto-unseal
- More complex bootstrap (Vault must exist before the cluster can read secrets from it)
- Overkill for initial build — worth adding after cluster is stable

**Reference:**
- External Secrets Operator: https://external-secrets.io/
- Vault on Kubernetes: https://developer.hashicorp.com/vault/docs/platform/k8s

---

### 2.2 Local Container Registry — Harbor or Zot

**What is missing:**
All container images are pulled from Docker Hub by default. Docker Hub rate-limits unauthenticated pulls to 100/6h. A cluster that is scaling frequently and pulling images on new nodes will hit these limits, causing pod startup failures with `ErrImagePull` errors.

**What a local registry adds:**
- **Harbor** — enterprise-grade CNCF container registry with image scanning (Trivy), replication, and RBAC
- **Zot** — lightweight OCI-compliant registry, minimal footprint
- All nodes pull from the local registry on the LAN instead of Docker Hub

**AWS parallel:** Harbor maps to Amazon ECR. Managing image pull secrets and configuring containerd to use a registry mirror is directly applicable to EKS + ECR workflows.

**Pros:**
- Eliminates Docker Hub rate limit failures
- Faster image pulls (LAN vs internet)
- Works when internet is down
- Image scanning before deployment (Harbor's Trivy integration)

**Cons:**
- Harbor is resource-intensive (Redis, PostgreSQL, multiple components)
- Zot is lighter but has fewer features
- Registry itself needs backup
- Adds another service to the bootstrap sequence

**Reference:**
- Harbor: https://goharbor.io/
- Zot: https://zotregistry.dev/
- containerd registry mirror config: https://github.com/containerd/containerd/blob/main/docs/hosts.md

---

### 2.3 NetworkPolicy Defaults

**What is missing:**
Calico is installed but no NetworkPolicy resources are defined. All pods can talk to all other pods across all namespaces. If any workload is compromised, it has unrestricted access to the monitoring stack, ArgoCD, and the webhook adapter.

**What to add:**
A default-deny NetworkPolicy in each namespace, with explicit allow rules for traffic that is actually needed:
- `monitoring` namespace: node-exporter can receive Prometheus scrape traffic; Grafana can reach Prometheus; AlertManager can reach the webhook adapter
- `argocd` namespace: can reach GitHub (HTTPS egress); can reach k8s API
- `ingress-nginx` namespace: can receive traffic on 80/443
- Control plane ↔ worker: kubeadm requires specific ports (6443, 2379–2380, 10250–10255)

**AWS parallel:** Maps to AWS Security Groups and VPC security policies for EKS. NetworkPolicy is a CKS exam topic.

**Pros:**
- Blast radius reduction if a workload is compromised
- CKS study material
- Low overhead — NetworkPolicy is just YAML

**Cons:**
- Easy to accidentally block legitimate traffic and cause mysterious failures
- Adds YAML to maintain per namespace

**Reference:** https://kubernetes.io/docs/concepts/services-networking/network-policies/

---

### 2.4 Longhorn — Distributed Block Storage for Persistent Volumes

**What is missing:**
The current plan uses whatever default storage is available on Proxmox nodes (likely `local-lvm`). Persistent Volumes (used by Prometheus, Grafana, Loki) are tied to a specific node — if that node goes down, the PV is inaccessible.

**What Longhorn adds:**
- Distributed block storage that replicates PV data across multiple worker nodes
- If a node goes down, the PV is still accessible from replicas on other nodes
- Built-in scheduled snapshots and backup to MinIO
- Managed by ArgoCD

**AWS parallel:** Longhorn maps to Amazon EBS with multi-AZ replication.

**Pros:**
- PVs survive node failures
- Built-in backup to MinIO (reuses existing infrastructure)
- CKA topic (persistent storage management)

**Cons:**
- Resource-intensive — Longhorn uses CPU and RAM for replication
- Network-intensive — replication traffic between nodes
- Overkill if your workloads are stateless

**Reference:** https://longhorn.io/docs/latest/

---

## Summary Table

| Item | Type | Complexity | AWS Career Value | Recommend Now? |
|---|---|---|---|---|
| 1.1 Cluster Autoscaler | Architecture change | High | Very High | After k8s basics are solid |
| 1.2 OpenTofu + MinIO | Architecture change | Low | High | Yes — open source, S3 parallel |
| 1.3 Actions Runner Controller | Architecture change | Medium | Medium | After cluster exists |
| 2.1 External Secrets + Vault | Addition | High | Very High | Later — after cluster stable |
| 2.2 Local registry (Harbor/Zot) | Addition | Medium | High | Later — after Docker Hub limits hit |
| 2.3 NetworkPolicy defaults | Addition | Low | High | Yes — CKS topic, easy YAML |
| 2.4 Longhorn storage | Addition | High | Medium | Later — only if using stateful workloads |
