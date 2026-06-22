# Alternate Suggestions & Additions

Independent analysis of the planned architecture — what I would change, what I would add, and what is worth questioning. Each item includes trade-offs so you can make informed decisions rather than just accepting or rejecting the suggestion.

This document does not replace PLAN.md or EXECUTION_PLAN.md. It sits alongside them as a "what if" reference.

**Status of items:** Items marked **[INCORPORATED]** have been merged into PLAN.md and EXECUTION_PLAN.md. Items marked **[SUGGESTION]** remain optional decisions.

---

## Section 1: Architectural Changes

These are things in the current design I would do differently if the constraints were looser.

---

### 1.1 Replace AlertManager → GitHub Actions Scaling with Cluster Autoscaler

**What the current plan does:**
AlertManager detects RAM pressure → fires webhook → webhook adapter → GitHub repository_dispatch → GitHub Actions runner wakes up → Terraform + Ansible provision a new VM → node joins cluster.

**The problem:**
This chain has significant latency. GitHub Actions has a cold-start delay of 30–90 seconds before a job even begins. Add AlertManager's 5-minute evaluation window, Terraform provisioning time (~60–90 seconds for a VM clone), Ansible configuration (~3–5 minutes), and kubeadm join (~2 minutes) — a scale-out event from trigger to Ready node takes **10–15 minutes minimum**. During that time, whatever is causing the memory pressure continues unchecked.

There is also a chain of failure points: if the runner is down, if GitHub's API is degraded, if the webhook adapter crashes — the scaling system is silent.

**The alternative: Kubernetes Cluster Autoscaler**
The Cluster Autoscaler is the standard Kubernetes-native solution for adding and removing nodes. It works by:
1. Watching for pods stuck in `Pending` state because no node has capacity
2. Deciding which node group to expand
3. Calling the cloud provider API to add a node
4. Once the node is Ready, the pending pods schedule automatically

This is how EKS, GKE, and AKS autoscaling works. The signal is pod scheduling pressure, not a RAM percentage — which is actually a better signal (you know you need more capacity when workloads literally cannot start, not just when RAM is high).

For Proxmox, there is a community Cluster Autoscaler cloud provider implementation:
- https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- Proxmox cloud provider: https://github.com/sergelogvinov/proxmox-cloud-controller-manager

**Pros of switching:**
- Kubernetes-native — this is exactly how AWS SysEng teams work with EKS autoscaling
- No AlertManager → GitHub → Actions chain — scaling decisions happen inside the cluster
- Responds to actual scheduling pressure, not a RAM threshold you need to tune
- No webhook adapter to maintain
- Direct CKA/AWS parallel (Cluster Autoscaler is a CKA topic)
- Cluster Autoscaler handles scale-in automatically (removes underutilised nodes safely)
- The three separate GitHub Actions workflows (deploy, remove, resize) collapse to one operator

**Cons of switching:**
- Proxmox cloud provider is community-maintained, not officially supported
- Cluster Autoscaler scales at the node group level, not the individual VM level — less fine-grained control over which Proxmox node a VM lands on (though the placement algorithm from PLAN.md could be encoded in the cloud provider)
- Removes the GitHub Actions learning element — the three workflows are good practice for your AWS tooling knowledge
- You lose the explicit "resize vertically first" logic — Cluster Autoscaler only adds nodes, it doesn't resize existing ones
- More complex to bootstrap (the cloud provider needs credentials and cluster access)

**Hybrid recommendation:**
Keep the GitHub Actions workflows for the resize (vertical scaling) path — that genuinely needs custom logic. Use Cluster Autoscaler for horizontal scale-out and scale-in. You get the best of both: Kubernetes-native autoscaling for the common case, and a custom workflow for the RAM-cap-driven vertical resize path.

---

### 1.2 HA Control Plane (3 Nodes Instead of 1) — [INCORPORATED]

**What the current plan does:**
Single control plane VM. If it goes down, `kubectl` stops working, new pods cannot be scheduled, the API server is unavailable, and your GitHub Actions workflows cannot communicate with the cluster.

**The problem:**
This is a genuine single point of failure. The control plane VM is the most critical component in the cluster. In a learning/homelab context this is acceptable if you understand the risk, but for anything resembling a "real" environment it is a significant gap. It also means you never practice HA control plane operations, which are tested on CKA and relevant to EKS multi-AZ setups.

**The alternative:**
kubeadm fully supports HA control plane with three nodes and a virtual IP:
- 3 control plane VMs (can be smaller: 2 CPU, 4 GB RAM each)
- **keepalived** provides a floating VIP (virtual IP) that always points to a healthy control plane node
- **HAProxy** load-balances the API server port (6443) across all three control plane nodes
- etcd runs as a static pod on each control plane node (stacked topology)

This maps directly to how EKS runs multi-AZ control planes and is a core CKA exam topic (kubeadm HA setup).

**Pros:**
- Control plane survives the loss of one node (2/3 quorum still functional)
- Direct CKA study material — HA control plane is tested
- Maps to EKS multi-AZ architecture
- You learn etcd quorum, PKI certificate distribution, kubeconfig with VIP endpoint

**Cons:**
- Three more VMs to manage (though small ones)
- More complex Ansible controlplane role (certificate distribution, HAProxy/keepalived config)
- keepalived requires multicast or unicast between nodes — needs Proxmox network config
- More Proxmox resources consumed
- Bootstrap workflow becomes significantly more complex

**Reference:**
https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/

---

### 1.3 OpenTofu + MinIO Instead of Terraform Cloud

**What the current plan does:**
Start with Terraform Cloud for state, migrate to MinIO later.

**The concern:**
HashiCorp changed Terraform's license from MPL to BSL in August 2023. Terraform is no longer truly open source. If you are learning for a career in infrastructure, building on a tool with a restrictive license is worth noting. The community forked it as **OpenTofu** under the OpenTF Foundation (now Linux Foundation), which is API-compatible and under the original MPL license.

**The alternative:**
Use **OpenTofu** from the start with **MinIO** on Proxmox as the S3-compatible state backend.

- OpenTofu is a drop-in replacement — same HCL syntax, same provider ecosystem, same `bpg/proxmox` provider works without modification
- MinIO runs as a standalone VM on Proxmox (not inside k8s — pre-cluster, always available)
- State stored in MinIO with object locking for state file locking (no DynamoDB needed)
- 100% self-hosted, no external dependencies, no account required
- The S3 backend config in OpenTofu is identical to what you would write for AWS S3 — maximum AWS learning parallel

**Pros:**
- Fully open source, no license concerns
- No Terraform Cloud account or token — fewer external dependencies
- MinIO S3 backend = identical config to real AWS S3 backend (muscle memory for AWS work)
- State lives on your LAN — no external service dependency for CI/CD
- Learn the S3 backend pattern that enterprises actually use on AWS

**Cons:**
- OpenTofu is newer — slightly less StackOverflow/blog coverage than Terraform (catching up fast)
- You must manage MinIO availability (it must exist before any Terraform/OpenTofu runs)
- MinIO needs its own VM or a place to run before the cluster exists (chicken-and-egg, but solvable — run it on the Proxmox host directly or as a dedicated small VM)
- Some enterprise tooling still references "Terraform" specifically

**MinIO reference:** https://min.io/docs/minio/linux/index.html
**OpenTofu:** https://opentofu.org/docs/

---

### 1.4 Actions Runner Controller Instead of a Static Runner VM

**What the current plan does:**
A dedicated VM on Proxmox runs the GitHub Actions self-hosted runner as a persistent service.

**The problem:**
This VM is a single point of failure. If it goes down, no workflows can run — including emergency scale-out events. It also consumes resources 24/7 when most of the time it is idle.

**The alternative: Actions Runner Controller (ARC)**
ARC is a Kubernetes operator that runs GitHub Actions runners as pods inside the cluster itself. It provides:
- Ephemeral runners: each job gets a fresh pod, which is destroyed after the job completes (no state pollution between runs)
- Autoscaling: ARC scales the runner pod count based on the GitHub Actions job queue — zero runners when idle, N runners when N jobs are queued
- Managed by ArgoCD like everything else — runner configuration is a Git commit

The irony/elegance: the cluster that the runners manage also runs the runners. Once bootstrapped, you deploy ARC via ArgoCD and the static runner VM becomes unnecessary (keep it only for the bootstrap workflow).

**Pros:**
- No single point of failure — runner pods can be rescheduled on any worker node
- Ephemeral runners — each job starts clean, no contamination from previous runs
- Autoscaling — zero resource consumption when idle
- Managed by ArgoCD — runner config changes are Git commits
- Modern approach — how large engineering teams run self-hosted runners at scale

**Cons:**
- Chicken-and-egg: ARC runs inside the cluster, but you need a runner to bootstrap the cluster. Solution: keep the static runner VM for bootstrap only, then deploy ARC via ArgoCD after bootstrap and decommission the VM.
- Slightly more complex setup (ARC operator + RunnerDeployment CRDs)
- Runners run as pods, so they have Kubernetes-level isolation but not VM-level isolation — security consideration if you run untrusted code
- The runner pods need access to the Docker socket or a rootless build tool (kaniko/buildah) if building container images

**Reference:** https://github.com/actions/actions-runner-controller

---

### 1.5 Scale on CPU + RAM + Disk, Not RAM Alone — [INCORPORATED]

**What the current plan does:**
Scale based on RAM threshold (>75% pressure, <30% idle).

**The problem:**
RAM is only one dimension of resource pressure. A node can be at 25% RAM utilisation but 100% CPU, which is equally bad for workload performance — pods become CPU-starved, latency spikes, and no amount of RAM scaling helps.

Scaling on RAM alone also has false-positive risk: a single process doing a large in-memory sort can temporarily spike RAM usage and trigger a scale-out that is not needed once the sort completes.

**The alternative: Multi-metric composite alert**

Define four alert rules instead of three:

| Alert | Condition | Action |
|---|---|---|
| `NodeMemoryPressure` | Single node RAM > 75% for 5 min | Resize (vertical) |
| `NodeCPUPressure` | Single node CPU > 80% for 5 min | Resize or scale-out |
| `ClusterHighLoad` | ALL nodes RAM > 75% OR ALL nodes CPU > 80% | Scale-out immediately |
| `NodeUnderutilised` | Node RAM < 30% AND CPU < 20% for 15 min | Scale-in |

The CPU PromQL:
```promql
# Per-node CPU usage %
100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

The scale-in condition now requires BOTH RAM and CPU to be low — avoiding removing a node that is CPU-bound but RAM-idle.

**Pros:**
- More accurate scaling signals — matches real workload behaviour
- Scale-in protection is stronger (both metrics must be low)
- CPU pressure is a distinct trigger that RAM cannot capture
- Maps to how AWS Auto Scaling Groups define scaling policies (multi-metric)

**Cons:**
- Two more alert rules to define and tune
- More complex resize-worker workflow (must check both CPU and RAM allocation)
- CPU hot-add to a running VM is even more complex than RAM hot-add — vertical CPU scaling may always require a drain/reboot cycle

---

### 1.6 Notification Architecture: Split Cluster Events from GitHub Actions Events — [INCORPORATED]

**What the current plan does:**
All Discord notifications are fired from within GitHub Actions workflow steps. This means: if GitHub Actions is down, if the runner is down, or if the workflow fails before reaching the notification step — you get no Discord message about what happened.

**The alternative: Dual notification paths**

| Event type | Source | Tool |
|---|---|---|
| GitHub Actions workflow started/completed | Inside the workflow | Discord webhook (as planned) |
| k8s node NotReady, pod crash, OOM kill | Inside the cluster | AlertManager → Discord webhook directly |
| ArgoCD app sync failed/succeeded | Inside the cluster | ArgoCD Notifications Controller |
| Proxmox VM down (outside k8s) | Proxmox API | Proxmox built-in alerts or a separate Prometheus exporter |

AlertManager can send directly to a Discord webhook without going through GitHub — you just configure a Discord `webhook_config` receiver in AlertManager that posts to your Discord channel directly, bypassing the GitHub API entirely.

ArgoCD has a native Notifications Controller that integrates with Discord:
- Sends a message when an app goes out-of-sync, sync fails, or health degrades
- Runs inside the cluster, independent of GitHub Actions
- Reference: https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/

This means you get Discord notifications about cluster health even when the scaling workflows are not running.

**Pros:**
- Cluster health notifications are independent of GitHub Actions availability
- ArgoCD sync failures notify you immediately without waiting for a workflow to run
- AlertManager can notify Discord directly for any alert (not just the three scaling ones)
- Better separation of concerns: cluster observes itself, CI/CD observes workflows

**Cons:**
- Two notification paths to configure and maintain
- Potential for duplicate notifications if an alert fires both the GitHub Actions path AND the Discord direct path
- Slightly more complex AlertManager config (some receivers go to webhook adapter for GitHub, others go to Discord directly)

---

## Section 2: Additions to the Project

These are things not in the current plan that I would add.

---

### 2.1 Velero — Backup and Disaster Recovery

**What is missing:**
The current plan has no backup strategy. If the control plane VM is lost, the etcd data is gone — the entire cluster configuration (deployments, services, configmaps, secrets, persistent volume claims) disappears with it.

**What Velero does:**
Velero backs up Kubernetes resources (as YAML) and persistent volume snapshots to object storage (MinIO on Proxmox, or AWS S3). It can restore an entire cluster namespace or individual resources.

Additionally: etcd itself should be snapshotted regularly via a CronJob on the control plane node (`etcdctl snapshot save`). kubeadm makes this straightforward.

**Combination approach:**
- Velero for k8s resource backup (apps, configs, PVs) → stored in MinIO
- etcd snapshot CronJob for cluster state backup → stored in MinIO
- Test restore quarterly — backup without restore testing is not a backup strategy

**AWS parallel:** Velero is architecturally similar to AWS Backup for EKS workloads. etcd snapshots are what AWS takes internally for EKS control plane state.

**Pros:**
- Actual disaster recovery capability — you can rebuild from backup
- etcd backup is a CKA exam topic (and AWS interview topic)
- Stored in MinIO (same backend as Terraform state) — simple
- Managed by ArgoCD — backup schedule is a Git commit

**Cons:**
- Another operator to manage (Velero CRDs, Velero server Deployment)
- MinIO needs sufficient storage for backup retention
- Backup restore testing adds operational overhead

**Reference:** https://velero.io/docs/latest/

---

### 2.2 Loki + Promtail — Log Aggregation

**What is missing:**
The current monitoring stack (Prometheus + Grafana) gives you metrics. It tells you how much RAM a node is using but not WHY it is high. If a scale-out event fails, you have no place to look at what Ansible output was, what kubeadm error occurred, or what the webhook adapter logged.

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
- GitHub Actions workflow logs are also available but expire after 90 days — cluster logs can be retained longer
- Adds a second "pillar of observability" (logs) to the existing metrics

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
- Vault can also issue short-lived dynamic credentials (e.g. generate a Proxmox token that expires in 1 hour, used for one Terraform run)

**AWS parallel:** This is exactly how AWS Secrets Manager + External Secrets Operator works on EKS. This is a very commonly asked about pattern in AWS SysEng interviews. Vault on-prem maps directly to AWS Secrets Manager in the cloud.

**Pros:**
- Secrets are encrypted at rest (Vault's storage backend)
- Audit log of every secret access
- Secret rotation without redeploying k8s resources
- Dynamic credentials (short-lived Proxmox tokens per workflow run)
- Direct AWS Secrets Manager learning parallel

**Cons:**
- Vault is significant additional infrastructure (needs its own VM, HA setup for production)
- Vault unsealing after reboot requires manual intervention or auto-unseal (KMS)
- External Secrets Operator adds another controller to manage
- More complex bootstrap (Vault must exist before the cluster can read secrets from it)
- Overkill for a homelab — but high learning value for the career goal

**Reference:**
- External Secrets Operator: https://external-secrets.io/
- Vault on Kubernetes: https://developer.hashicorp.com/vault/docs/platform/k8s

---

### 2.4 Local Container Registry — Harbor or Zot

**What is missing:**
All container images are pulled from Docker Hub by default. Docker Hub rate-limits unauthenticated pulls to 100/6h and free-tier authenticated pulls to 200/6h. A cluster that is scaling frequently and pulling images on new nodes will hit these limits, causing pod startup failures with `ErrImagePull` errors.

**What a local registry adds:**
- **Harbor** — enterprise-grade CNCF container registry with image scanning (Trivy), replication, and RBAC
- **Zot** — lightweight OCI-compliant registry, minimal footprint
- All nodes pull from the local registry on the LAN instead of Docker Hub — faster (LAN vs internet) and no rate limits
- Images are mirrored from Docker Hub to the local registry as a one-time or scheduled sync

**AWS parallel:** Harbor maps to Amazon ECR (Elastic Container Registry). Understanding how to operate a private registry, manage image pull secrets, and configure containerd to use a registry mirror is directly applicable to EKS + ECR workflows.

**Pros:**
- Eliminates Docker Hub rate limit failures
- Faster image pulls (LAN vs internet)
- Works when internet is down
- Image scanning before deployment (Harbor's built-in Trivy integration)
- Managed by ArgoCD

**Cons:**
- Harbor is resource-intensive (Redis, PostgreSQL, multiple components)
- Zot is lighter but has fewer features
- Initial image mirroring takes time
- Registry itself needs backup (all your cached images)
- Adds another service to the bootstrap sequence (must exist before nodes pull images)

**Reference:**
- Harbor: https://goharbor.io/
- Zot: https://zotregistry.dev/
- containerd registry mirror config: https://github.com/containerd/containerd/blob/main/docs/hosts.md

---

### 2.5 NetworkPolicy Defaults

**What is missing:**
Calico is installed but no NetworkPolicy resources are defined. This means all pods can talk to all other pods across all namespaces — a flat network with no isolation. If any workload is compromised, it has unrestricted access to all other workloads including the monitoring stack, ArgoCD, and the webhook adapter (which holds the GitHub PAT).

**What to add:**
A default-deny NetworkPolicy in each namespace, with explicit allow rules for the traffic that is actually needed:

- `monitoring` namespace: node-exporter can receive Prometheus scrape traffic; Grafana can reach Prometheus; AlertManager can reach the webhook adapter
- `argocd` namespace: can reach GitHub (HTTPS egress); can reach k8s API
- `ingress-nginx` namespace: can receive traffic from internet on 80/443
- Worker joining: kubeadm join requires specific ports between nodes (6443, 2379-2380, 10250-10255)

**AWS parallel:** This maps to AWS Security Groups and VPC security policies for EKS node groups. Understanding and writing NetworkPolicy is a CKS exam topic.

**Pros:**
- Blast radius reduction if a workload is compromised
- CKS study material (NetworkPolicy is a major CKS topic)
- Maps to AWS Security Group thinking for EKS
- Low overhead — NetworkPolicy is just YAML

**Cons:**
- Getting the allow rules right without breaking things requires careful planning
- Easy to accidentally block legitimate traffic and cause mysterious failures
- Adds YAML to maintain per namespace

**Reference:** https://kubernetes.io/docs/concepts/services-networking/network-policies/

---

### 2.6 Branch Protection + Required Status Checks on Terraform

**What the current plan does:**
The `terraform-plan.yml` CI workflow runs on PRs and posts the plan as a PR comment — but it is advisory only. A PR that would destroy production VMs can be merged without anyone explicitly acknowledging the plan.

**What to add:**
Configure branch protection rules on `main`:
1. Require `terraform-plan` as a passing status check before merge
2. Require at least 1 PR approval (even if you are the only contributor — approve your own changes after reviewing the plan output)
3. Prevent force-pushes to `main`

Additionally: add a `terraform-plan-check` step that scans the plan JSON output for any `destroy` operations and fails the CI check if unexpected destroys are present. This means a PR that would accidentally destroy VMs cannot be merged without an explicit override.

**Pros:**
- Prevents accidental infrastructure destruction via a bad `terraform apply`
- Mirrors enterprise infrastructure change management practices
- The "no unexpected destroys" check is a safety net with real value in production
- Audit trail — every infrastructure change has a PR with a plan attached

**Cons:**
- Adds friction to the development loop (requires approving your own PRs)
- The unexpected-destroy check needs to know which destroys are expected (e.g. removing a worker is intentional) — needs careful scoping
- False positives possible if the check is too aggressive

**Reference:** https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches

---

### 2.7 Proxmox Prometheus Exporter

**What is missing:**
The current monitoring stack scrapes metrics from inside the Kubernetes cluster (node-exporter, kube-state-metrics). It has no visibility into the Proxmox layer itself — you cannot see Proxmox node CPU/RAM, storage pool utilisation, VM status, or whether a Proxmox node itself is under pressure.

**What to add:**
The `prometheus-pve-exporter` scrapes the Proxmox API and exposes VM and node metrics to Prometheus.

This gives you:
- Per-Proxmox-node CPU/RAM/storage utilisation
- VM power state (which VMs are running, stopped, etc.)
- Storage pool free space
- Network throughput per Proxmox node

This is important context for the placement algorithm: a Proxmox node might be under capacity according to `node_capacities.json` but the Proxmox host itself is CPU-saturated. With the exporter, you can add a Proxmox-level check to the placement algorithm.

**Pros:**
- Complete observability: k8s layer + hypervisor layer in one Grafana instance
- Placement algorithm can use real Proxmox host metrics instead of just a JSON capacity file
- Early warning if a Proxmox node is approaching physical limits

**Cons:**
- Another exporter to deploy and configure
- Needs Proxmox API credentials (another secret to manage)
- Dashboard creation or import required

**Reference:** https://github.com/prometheus-pve/prometheus-pve-exporter

---

### 2.8 Automated kubeadm Join Token Handling

**What is currently unaddressed:**
kubeadm bootstrap tokens expire after 24 hours by default. The deploy-worker GitHub Actions workflow needs a valid join token to add a new worker. If the token has expired (e.g. the cluster has been running for more than 24 hours with no new workers), the `kubeadm join` step will fail silently or with a cryptic error.

**What to add:**
The deploy-worker workflow must generate a fresh join token before running Ansible:
1. SSH into the control plane node
2. Run `kubeadm token create --print-join-command`
3. Capture the output
4. Pass it to the Ansible worker role as a variable

The token should be single-use and short-lived (1 hour is sufficient for a workflow run). This is distinct from the discovery token hash, which is permanent — only the bootstrap token itself expires.

This is a subtle but workflow-breaking issue that is easy to miss until the first time you try to add a worker 25 hours after bootstrapping.

**Pros:**
- Workflows reliably succeed regardless of cluster uptime
- Short-lived tokens are more secure (principle of least privilege)

**Cons:**
- Adds one SSH step and one kubeadm command to the deploy-worker workflow
- The workflow needs SSH access to the control plane node (already have it via the Ansible key)

**Reference:** https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/

---

### 2.9 Longhorn — Distributed Block Storage for Persistent Volumes

**What is missing:**
The current plan uses whatever default storage is available on the Proxmox nodes (likely `local-lvm` or `local`). Persistent Volumes (used by Prometheus, Grafana, Loki) are tied to a specific node — if that node goes down, the PV is inaccessible.

**What Longhorn adds:**
- Distributed block storage that replicates PV data across multiple worker nodes
- If a node goes down, the PV is still accessible from the replicas on other nodes
- Built-in scheduled snapshots and backup to S3/MinIO
- Grafana dashboard available (shows volume health, replica status)
- Managed by ArgoCD

**AWS parallel:** Longhorn maps to Amazon EBS with multi-AZ replication, or more accurately to EFS for shared access. The concept of distributed storage with replication directly maps to how AWS manages EBS volume availability across AZs.

**Pros:**
- PVs survive node failures
- Built-in backup to MinIO
- No dependency on Proxmox-level storage for k8s workloads
- CKA topic (persistent storage management)

**Cons:**
- Resource-intensive — Longhorn uses CPU and RAM for replication
- Network-intensive — replication traffic between nodes
- Complex to operate at the storage layer
- Overkill if your workloads are stateless (only adds value for Prometheus data, Loki logs, etc.)

**Reference:** https://longhorn.io/docs/latest/

---

### 2.10 Renovate Bot — Automated Dependency Updates

**What is missing:**
The current plan pins versions for Terraform providers, Helm chart versions, Kubernetes versions, and container image tags. These versions will go stale. Security CVEs are regularly discovered in Helm charts and container images. Without a mechanism to track and update versions, the cluster drifts further from current over time.

**What Renovate Bot does:**
- Runs as a scheduled GitHub Actions job (or GitHub App)
- Scans the repo for version references (Helm chart versions in ArgoCD Applications, Terraform provider versions, image tags in k8s manifests)
- Opens pull requests to update each dependency when a new version is released
- These PRs trigger the `terraform-plan` CI check and can be reviewed before merging

**AWS parallel:** This mirrors how AWS Managed Services (EKS managed node groups, RDS) handle version updates — periodic update notifications, then a controlled apply window. Renovate simulates this for self-managed infrastructure.

**Pros:**
- Dependencies stay current with minimal manual work
- Security patches get PR'd automatically
- Each update is a separate PR with a clear scope
- Works with Helm charts, Terraform providers, container images, GitHub Actions, everything

**Cons:**
- Can generate a lot of PRs if many dependencies are tracked (configure grouping rules)
- Renovate itself needs a GitHub App token or PAT
- Auto-merging updates without testing can break things — use with branch protection

**Reference:** https://docs.renovatebot.com/

---

## Summary Table

| Item | Type | Complexity | AWS Career Value | Recommend Now? |
|---|---|---|---|---|
| 1.1 Cluster Autoscaler | Architecture change | High | Very High | After k8s basics are solid |
| 1.2 HA Control Plane | Architecture change | Medium | High | Yes — CKA topic |
| 1.3 OpenTofu + MinIO | Architecture change | Low | High | Yes — open source, S3 parallel |
| 1.4 Actions Runner Controller | Architecture change | Medium | Medium | After cluster exists |
| 1.5 CPU + RAM scaling | Architecture change | Low | Medium | Yes — easy addition |
| 1.6 Split notifications | Architecture change | Low | Low | Yes — easy, more resilient |
| 2.1 Velero backup | Addition | Low | High | Yes — CKA + AWS backup topic |
| 2.2 Loki logs | Addition | Low | High | Yes — observability completeness |
| 2.3 External Secrets + Vault | Addition | High | Very High | Later — after cluster stable |
| 2.4 Local registry (Harbor/Zot) | Addition | Medium | High | Later — after Docker Hub limits hit |
| 2.5 NetworkPolicy defaults | Addition | Low | High | Yes — CKS topic, easy YAML |
| 2.6 Branch protection | Addition | Low | Medium | Yes — zero cost, good practice |
| 2.7 Proxmox exporter | Addition | Low | Medium | Yes — completes observability |
| 2.8 Token refresh in deploy-worker | Addition | Low | Low | Yes — prevents silent failures |
| 2.9 Longhorn storage | Addition | High | Medium | Later — only if using stateful workloads |
| 2.10 Renovate Bot | Addition | Low | Medium | Yes — low effort, high value over time |

---

## Highest-Priority Picks (Do These First)

If forced to choose the most impactful changes from this list to incorporate now, before building starts:

1. **HA Control Plane** — one decision made during initial design, painful to retrofit later. Three control plane VMs is a build-once choice.
2. **OpenTofu + MinIO** — replaces Terraform Cloud entirely, removes an external dependency, better AWS parallel.
3. **CPU + RAM as dual scaling metrics** — trivial to add two extra alert rules now vs retrofitting later.
4. **kubeadm join token refresh** — add this to the deploy-worker workflow spec now; it will definitely be needed.
5. **Velero + etcd backup** — non-negotiable for anything you care about. Add to the ArgoCD manifests list from the start.
6. **Loki** — deploy alongside kube-prometheus-stack from day one. Retrofitting log collection later means losing historical context.
7. **NetworkPolicy defaults** — write the deny-all policies as part of namespace creation. Easier to add exceptions than to add policies after the fact.
