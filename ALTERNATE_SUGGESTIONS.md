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
This chain has significant latency. GitHub Actions has a cold-start delay of 30–90 seconds before a job even begins. Add AlertManager's 5-minute evaluation window, Terraform provisioning time (~60–90 seconds for a VM clone), Ansible configuration (~3–5 minutes), and kubeadm join (~2 minutes) — a scale-out event from trigger to Ready node takes **10–15 minutes minimum**. During that time, whatever is causing the pressure continues unchecked.

There is also a chain of failure points: if the runner is down, if GitHub's API is degraded, if the webhook adapter crashes — the scaling system is silent.

**The alternative: Kubernetes Cluster Autoscaler**
The Cluster Autoscaler is the standard Kubernetes-native solution for adding and removing nodes. It works by:
1. Watching for pods stuck in `Pending` state because no node has capacity
2. Deciding which node group to expand
3. Calling the cloud provider API to add a node
4. Once the node is Ready, the pending pods schedule automatically

This is how EKS, GKE, and AKS autoscaling works. The signal is pod scheduling pressure, not a resource percentage — which is actually a better signal (you know you need more capacity when workloads literally cannot start, not just when RAM is high).

For Proxmox, there is a community Cluster Autoscaler cloud provider implementation:
- https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- Proxmox cloud provider: https://github.com/sergelogvinov/proxmox-cloud-controller-manager

**Pros:**
- Kubernetes-native — this is exactly how AWS SysEng teams work with EKS autoscaling
- No AlertManager → GitHub → Actions chain — scaling decisions happen inside the cluster
- Responds to actual scheduling pressure, not a metric threshold you need to tune
- No webhook adapter to maintain
- Direct CKA/AWS parallel (Cluster Autoscaler is a CKA topic)
- Cluster Autoscaler handles scale-in automatically
- The deploy and remove GitHub Actions workflows collapse to one operator

**Cons:**
- Proxmox cloud provider is community-maintained, not officially supported
- Less fine-grained control over which Proxmox node a VM lands on
- Removes the GitHub Actions learning element — the three workflows are good practice for your AWS tooling knowledge
- You lose the explicit "resize vertically first" logic — Cluster Autoscaler only adds nodes, it doesn't resize existing ones
- More complex to bootstrap

**Hybrid recommendation:**
Keep the GitHub Actions workflows for the resize (vertical scaling) path — that genuinely needs custom logic. Use Cluster Autoscaler for horizontal scale-out and scale-in. You get the best of both: Kubernetes-native autoscaling for the common case, and a custom workflow for the vertical resize path.

---

### 1.2 OpenTofu + MinIO Instead of Terraform Cloud

**What the current plan does:**
Start with Terraform Cloud for state, migrate to MinIO later.

**The concern:**
HashiCorp changed Terraform's license from MPL to BSL in August 2023. Terraform is no longer truly open source. The community forked it as **OpenTofu** under the Linux Foundation, which is API-compatible and under the original MPL license.

**The alternative:**
Use **OpenTofu** from the start with **MinIO** on Proxmox as the S3-compatible state backend.

- OpenTofu is a drop-in replacement — same HCL syntax, same provider ecosystem, same `bpg/proxmox` provider works without modification
- MinIO runs as a standalone VM on Proxmox (not inside k8s — pre-cluster, always available)
- State stored in MinIO with object locking for state file locking
- 100% self-hosted, no external dependencies, no account required
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
ARC is a Kubernetes operator that runs GitHub Actions runners as pods inside the cluster itself. It provides:
- Ephemeral runners: each job gets a fresh pod, destroyed after the job completes (no state pollution between runs)
- Autoscaling: ARC scales runner pod count based on the GitHub Actions job queue — zero runners when idle
- Managed by ArgoCD like everything else — runner configuration is a Git commit

The cluster that the runners manage also runs the runners. Once bootstrapped, deploy ARC via ArgoCD and the static runner VM is no longer needed (keep it only for the bootstrap workflow itself).

**Pros:**
- No single point of failure — runner pods can be rescheduled on any worker node
- Ephemeral runners — each job starts clean
- Zero resource consumption when idle
- Managed by ArgoCD — runner config changes are Git commits

**Cons:**
- Chicken-and-egg: ARC runs inside the cluster, but you need a runner to bootstrap the cluster. The static VM is still required for the bootstrap phase.
- Slightly more complex setup (ARC operator + RunnerDeployment CRDs)
- Runners run as pods — Kubernetes-level isolation, not VM-level isolation
- Needs Docker socket access or a rootless build tool if building container images

**Reference:** https://github.com/actions/actions-runner-controller

---

## Section 2: Additions to the Project

---

### 2.1 Velero — Backup and Disaster Recovery

**What is missing:**
The current plan has no backup strategy. If all three control plane VMs were lost simultaneously (unlikely but possible), the etcd data and all cluster configuration disappears.

**What Velero does:**
Velero backs up Kubernetes resources (as YAML) and persistent volume snapshots to object storage (MinIO on Proxmox, or AWS S3). It can restore an entire cluster namespace or individual resources.

Additionally: etcd itself should be snapshotted regularly via a CronJob on the control plane nodes (`etcdctl snapshot save`). Even with HA control plane (3 nodes), etcd backup is a separate concern from quorum.

**Combination approach:**
- Velero for k8s resource backup (apps, configs, PVs) → stored in MinIO
- etcd snapshot CronJob for cluster state backup → stored in MinIO
- Test restore periodically — backup without restore testing is not a backup strategy

**AWS parallel:** Velero is architecturally similar to AWS Backup for EKS workloads. etcd snapshots are what AWS takes internally for EKS control plane state.

**Pros:**
- Actual disaster recovery capability
- etcd backup is a CKA exam topic (and AWS interview topic)
- Stored in MinIO (same backend as Terraform state) — reuses existing infrastructure
- Managed by ArgoCD — backup schedule is a Git commit

**Cons:**
- Another operator to manage (Velero CRDs, Velero server Deployment)
- MinIO needs sufficient storage for backup retention
- Backup restore testing adds operational overhead

**Reference:** https://velero.io/docs/latest/

---

### 2.2 Loki + Promtail — Log Aggregation

**What is missing:**
The current monitoring stack gives you metrics. It tells you how much RAM a node is using but not WHY it is high. If a scale-out event fails, you have no place to look at what Ansible output was, what kubeadm error occurred, or what the webhook adapter logged.

**What Loki + Promtail adds:**
- **Promtail** runs as a DaemonSet on every node, collecting container and system logs
- **Loki** stores and indexes those logs
- **Grafana** displays them alongside your metrics — one UI for both

You can correlate: "RAM spiked at 14:32" → look at logs from that exact time window in Grafana.

The kube-prometheus-stack can be extended with Loki via the `grafana-loki-stack` Helm chart, or deployed as a separate ArgoCD Application.

**AWS parallel:** Loki maps to AWS CloudWatch Logs. Promtail maps to the CloudWatch Agent. The Grafana correlation of metrics + logs maps to CloudWatch Container Insights.

**Pros:**
- Logs and metrics in one Grafana UI — no SSH-ing into nodes to read logs
- Essential for debugging scale events (why did the workflow fail? what did Ansible output?)
- Adds the second pillar of observability (logs) to the existing metrics

**Cons:**
- Loki can be resource-hungry at scale (less of an issue for a homelab)
- Another Helm chart to configure and maintain
- Log retention and storage planning required

**Reference:** https://grafana.com/docs/loki/latest/

---

### 2.3 External Secrets Operator + Vault

**What is missing:**
Secrets management in the current plan has several weaknesses:
- The kubeconfig in GitHub Secrets grants full cluster-admin to anyone who can access the repo settings
- The Proxmox API token can create and destroy VMs — if leaked, it is dangerous
- The webhook adapter's GitHub PAT is stored in a k8s Secret, which in etcd is base64-encoded (not encrypted at rest by default)
- No secret rotation mechanism

**What External Secrets Operator + Vault does:**
- **HashiCorp Vault** (deployed on Proxmox, outside k8s) stores all secrets with encryption, access policies, and audit logging
- **External Secrets Operator** is a k8s operator that reads secrets from Vault and syncs them into k8s Secrets automatically
- Secrets in k8s are derived from Vault at runtime — they are never committed to Git and can be rotated in Vault without touching k8s manifests
- Vault can issue short-lived dynamic credentials (e.g. a Proxmox token that expires in 1 hour, used for one Terraform run)

**AWS parallel:** This is exactly how AWS Secrets Manager + External Secrets Operator works on EKS. Vault on-prem maps directly to AWS Secrets Manager. A very commonly asked about pattern in AWS SysEng interviews.

**Pros:**
- Secrets are encrypted at rest
- Audit log of every secret access
- Secret rotation without redeploying k8s resources
- Dynamic credentials (short-lived tokens per workflow run)
- Direct AWS Secrets Manager learning parallel

**Cons:**
- Vault is significant additional infrastructure (needs its own VM)
- Vault unsealing after reboot requires manual intervention or auto-unseal (KMS)
- More complex bootstrap (Vault must exist before the cluster can read secrets from it)
- Overkill for initial build — worth adding after cluster is stable

**Reference:**
- External Secrets Operator: https://external-secrets.io/
- Vault on Kubernetes: https://developer.hashicorp.com/vault/docs/platform/k8s

---

### 2.4 Local Container Registry — Harbor or Zot

**What is missing:**
All container images are pulled from Docker Hub by default. Docker Hub rate-limits unauthenticated pulls to 100/6h. A cluster that is scaling frequently and pulling images on new nodes will hit these limits, causing pod startup failures with `ErrImagePull` errors.

**What a local registry adds:**
- **Harbor** — enterprise-grade CNCF container registry with image scanning (Trivy), replication, and RBAC
- **Zot** — lightweight OCI-compliant registry, minimal footprint
- All nodes pull from the local registry on the LAN instead of Docker Hub — faster and no rate limits
- Images are mirrored from Docker Hub as a one-time or scheduled sync

**AWS parallel:** Harbor maps to Amazon ECR. Managing image pull secrets and configuring containerd to use a registry mirror is directly applicable to EKS + ECR workflows.

**Pros:**
- Eliminates Docker Hub rate limit failures
- Faster image pulls (LAN vs internet)
- Works when internet is down
- Image scanning before deployment (Harbor's built-in Trivy integration)
- Managed by ArgoCD

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

### 2.5 NetworkPolicy Defaults

**What is missing:**
Calico is installed but no NetworkPolicy resources are defined. All pods can talk to all other pods across all namespaces — a flat network with no isolation. If any workload is compromised, it has unrestricted access to the monitoring stack, ArgoCD, and the webhook adapter (which holds the GitHub PAT).

**What to add:**
A default-deny NetworkPolicy in each namespace, with explicit allow rules for traffic that is actually needed:

- `monitoring` namespace: node-exporter can receive Prometheus scrape traffic; Grafana can reach Prometheus; AlertManager can reach the webhook adapter
- `argocd` namespace: can reach GitHub (HTTPS egress); can reach k8s API
- `ingress-nginx` namespace: can receive traffic on 80/443
- Control plane ↔ worker communication: kubeadm requires specific ports (6443, 2379–2380, 10250–10255)

**AWS parallel:** Maps to AWS Security Groups and VPC security policies for EKS node groups. NetworkPolicy is a CKS exam topic.

**Pros:**
- Blast radius reduction if a workload is compromised
- CKS study material
- Low overhead — NetworkPolicy is just YAML

**Cons:**
- Easy to accidentally block legitimate traffic and cause mysterious failures
- Getting the allow rules right without breaking things requires careful planning
- Adds YAML to maintain per namespace

**Reference:** https://kubernetes.io/docs/concepts/services-networking/network-policies/

---

### 2.6 Branch Protection + Required Status Checks on Terraform

**What the current plan does:**
The `terraform-plan.yml` CI workflow runs on PRs and posts the plan as a PR comment — but it is advisory only. A PR that would destroy production VMs can be merged without anyone explicitly acknowledging the plan output.

**What to add:**
Configure branch protection rules on `main`:
1. Require `terraform-plan` as a passing status check before merge
2. Require at least 1 PR approval
3. Prevent force-pushes to `main`

Additionally: add a `terraform-plan-check` step that scans the plan JSON output for any `destroy` operations and fails the CI check if unexpected destroys are present.

**Pros:**
- Prevents accidental infrastructure destruction
- Mirrors enterprise infrastructure change management practices
- Audit trail — every infrastructure change has a PR with a plan attached

**Cons:**
- Adds friction to the development loop
- The unexpected-destroy check needs to know which destroys are expected (e.g. removing a worker is intentional) — needs careful scoping

**Reference:** https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches

---

### 2.7 Proxmox Prometheus Exporter

**What is missing:**
The current monitoring stack scrapes metrics from inside the Kubernetes cluster only. It has no visibility into the Proxmox layer — you cannot see Proxmox node CPU/RAM, storage pool utilisation, VM status, or whether a Proxmox host itself is under pressure.

**What to add:**
The `prometheus-pve-exporter` scrapes the Proxmox API and exposes VM and node metrics to Prometheus:
- Per-Proxmox-node CPU/RAM/storage utilisation
- VM power state (which VMs are running, stopped, etc.)
- Storage pool free space
- Network throughput per Proxmox node

This is important context for the placement algorithm: a Proxmox node might be under capacity according to `node_capacities.json` but the Proxmox host itself is CPU-saturated.

**Pros:**
- Complete observability: k8s layer + hypervisor layer in one Grafana instance
- Placement algorithm can be enhanced to use real Proxmox host metrics
- Early warning if a Proxmox node is approaching physical limits

**Cons:**
- Another exporter to deploy and configure
- Needs Proxmox API credentials (another secret to manage)

**Reference:** https://github.com/prometheus-pve/prometheus-pve-exporter

---

### 2.8 Longhorn — Distributed Block Storage for Persistent Volumes

**What is missing:**
The current plan uses whatever default storage is available on Proxmox nodes (likely `local-lvm`). Persistent Volumes (used by Prometheus, Grafana, Loki) are tied to a specific node — if that node goes down, the PV is inaccessible.

**What Longhorn adds:**
- Distributed block storage that replicates PV data across multiple worker nodes
- If a node goes down, the PV is still accessible from replicas on other nodes
- Built-in scheduled snapshots and backup to S3/MinIO
- Grafana dashboard for volume health and replica status
- Managed by ArgoCD

**AWS parallel:** Longhorn maps to Amazon EBS with multi-AZ replication. The concept of distributed storage with replication maps directly to how AWS manages EBS volume availability across AZs.

**Pros:**
- PVs survive node failures
- Built-in backup to MinIO
- CKA topic (persistent storage management)

**Cons:**
- Resource-intensive — Longhorn uses CPU and RAM for replication
- Network-intensive — replication traffic between nodes
- Overkill if your workloads are stateless

**Reference:** https://longhorn.io/docs/latest/

---

### 2.9 Renovate Bot — Automated Dependency Updates

**What is missing:**
The current plan pins versions for Terraform providers, Helm charts, Kubernetes, and container image tags. These versions will go stale. Security CVEs are regularly discovered in Helm charts and container images. Without a mechanism to track updates, the cluster drifts further from current over time.

**What Renovate Bot does:**
- Runs as a scheduled GitHub Actions job (or GitHub App)
- Scans the repo for version references (Helm chart versions in ArgoCD Applications, Terraform provider versions, image tags in k8s manifests)
- Opens pull requests to update each dependency when a new version is released
- These PRs trigger the `terraform-plan` CI check and can be reviewed before merging

**AWS parallel:** Mirrors how AWS Managed Services handle version updates — periodic update notifications, then a controlled apply window.

**Pros:**
- Dependencies stay current with minimal manual work
- Security patches get PR'd automatically
- Works with Helm charts, Terraform providers, container images, GitHub Actions, everything

**Cons:**
- Can generate noisy PRs if many dependencies update simultaneously (configure grouping rules)
- Renovate needs a GitHub App token or PAT
- Auto-merging updates without testing can break things — use with branch protection

**Reference:** https://docs.renovatebot.com/

---

## Summary Table

| Item | Type | Complexity | AWS Career Value | Recommend Now? |
|---|---|---|---|---|
| 1.1 Cluster Autoscaler | Architecture change | High | Very High | After k8s basics are solid |
| 1.2 OpenTofu + MinIO | Architecture change | Low | High | Yes — open source, S3 parallel |
| 1.3 Actions Runner Controller | Architecture change | Medium | Medium | After cluster exists |
| 2.1 Velero backup | Addition | Low | High | Yes — CKA + AWS backup topic |
| 2.2 Loki logs | Addition | Low | High | Yes — observability completeness |
| 2.3 External Secrets + Vault | Addition | High | Very High | Later — after cluster stable |
| 2.4 Local registry (Harbor/Zot) | Addition | Medium | High | Later — after Docker Hub limits hit |
| 2.5 NetworkPolicy defaults | Addition | Low | High | Yes — CKS topic, easy YAML |
| 2.6 Branch protection | Addition | Low | Medium | Yes — zero cost, good practice |
| 2.7 Proxmox exporter | Addition | Low | Medium | Yes — completes observability |
| 2.8 Longhorn storage | Addition | High | Medium | Later — only if using stateful workloads |
| 2.9 Renovate Bot | Addition | Low | Medium | Yes — low effort, high value over time |
