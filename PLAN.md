# K8s Cluster on Proxmox — GitOps + Dynamic Scaling Plan

## Context

You want a home-lab / learning environment running Kubernetes on Proxmox VMs that can:
1. Dynamically **deploy** new worker nodes via GitHub Actions
2. **Remove / destroy** workers when load drops
3. **Resize** workers — vertically first (up to 16 GB RAM cap), then horizontally if that cap is hit

The stack is intentionally chosen to map closely to what AWS Systems Engineers encounter: kubeadm mirrors EKS internals, Terraform mirrors CDK/CloudFormation workflow patterns, and ArgoCD/Flux mirror what teams run on top of EKS in production.

---

## Architecture Overview

```
GitHub Repo (source of truth)
    │
    ├── terraform/          ← VM lifecycle (Proxmox)
    ├── ansible/            ← Node configuration & cluster join
    ├── k8s/                ← Manifests / Helm charts (GitOps watched)
    └── .github/workflows/  ← Orchestration (deploy, remove, resize)

GitHub Actions (CI/CD orchestrator)
    │
    ├─→ Terraform → Proxmox API → creates/destroys VMs
    ├─→ Ansible   → SSH into VMs → configures OS, installs k8s, joins cluster
    └─→ Git push to k8s/ → GitOps operator reconciles workloads

Prometheus AlertManager
    └─→ Webhook → GitHub Actions (repository_dispatch) → resize/scale decision
```

---

## Layer 1: Infrastructure — Proxmox + Terraform

### What Terraform does here
Terraform talks to the Proxmox API to create/destroy VMs (QEMU guests).
It does NOT configure the OS — that is Ansible's job.

### Proxmox Terraform Provider Options

| Provider | Status | Notes |
|---|---|---|
| `bpg/proxmox` | **Recommended** — actively maintained | Full VM + cloud-init support, good docs |
| `telmate/proxmox` | Older, widely referenced in tutorials | More blog posts exist but slower to update |

Use `bpg/proxmox`. It supports:
- `proxmox_virtual_environment_vm` resource for full VM lifecycle
- Cloud-init user-data injection (sets hostname, SSH keys, network)
- VM cloning from a template (fast provisioning — create a Debian/Ubuntu template once)

### Proxmox VM Template (one-time setup)
Before Terraform can clone VMs quickly you need a base template:
1. Download an Ubuntu 24.04 cloud image onto Proxmox
2. Create a VM, attach the cloud image as a disk, convert to template
3. Terraform clones this template for every new worker

**Resource:** https://pve.proxmox.com/wiki/Cloud-Init_Support

### Terraform File Structure
```
terraform/
├── main.tf           ← provider config, VM resources
├── variables.tf      ← node count, CPU, RAM, disk size
├── outputs.tf        ← IP addresses passed to Ansible
├── worker.tf         ← worker node VM definition
├── controlplane.tf   ← control plane VM definition (static, not auto-scaled)
└── versions.tf       ← provider version pins
```

### Key Terraform Resources to Define

**Control plane VM** (static — deployed once, never auto-scaled):
- `proxmox_virtual_environment_vm.controlplane`
- Fixed CPU/RAM (e.g. 4 CPU, 8 GB RAM), always on a designated node

**Worker VM** (dynamic):
- `proxmox_virtual_environment_vm.worker` using `for_each` over a **map**, not `count`
- The map key is the worker's name (e.g. `worker-pve2-01`), the value contains its target Proxmox node, memory, and cores
- Using a map means adding or removing one worker does not cause Terraform to recreate others — it operates only on the changed key
- **Never use `count` for workers** — count-based resources are index-dependent, so removing worker index 1 causes Terraform to shift and recreate workers 2, 3, etc.

### Worker Naming Convention

Workers must be named to encode which Proxmox node they live on:
```
worker-<proxmox-node>-<sequence>
e.g. worker-pve2-01, worker-pve2-02, worker-pve1-01
```

This naming convention serves three purposes:
1. The deploy-worker workflow can count workers per node by querying `qm list` or the Proxmox API and filtering by name prefix
2. The remove-worker workflow knows exactly which Proxmox node to target for VM destruction without querying state
3. `kubectl get nodes` output shows which Proxmox host each k8s worker is backed by

### Multi-Node Placement Strategy

When your Proxmox environment spans multiple physical nodes (pve1, pve2, pve3...), each with different resource capacity, the deploy-worker workflow must decide WHERE to place a new VM before calling Terraform.

**Node capacity config** — stored in `terraform/node_capacities.json` (tracked in Git):
- A map of each Proxmox node name to its maximum allowed worker VMs
- Example: `pve1=3, pve2=6, pve3=4, pve4=2`
- These limits represent practical capacity (RAM headroom, CPU cores, storage), not hard Proxmox limits — you define them based on your hardware

**Placement algorithm (runs in the deploy-worker workflow before Terraform):**
1. Read `node_capacities.json` from the repo
2. Query the Proxmox API for each node: `GET /api2/json/nodes/{node}/qemu` — returns all VMs on that node
3. Filter the response to count only VMs whose names match the worker naming pattern (`worker-{node}-*`)
4. For each node: calculate `remaining = max_capacity - current_worker_count`
5. Select the node with the **highest remaining capacity**
6. Tiebreak rule: if two nodes have equal remaining capacity, prefer the one with the higher `max_capacity` value (it has more headroom overall)
7. If ALL nodes are at their max: fail the workflow with a descriptive error — do not attempt to place the VM

**Why highest remaining rather than first available:**
Placing on the node with the most headroom distributes load evenly across Proxmox hosts, avoiding a scenario where pve2 fills up while pve3 sits idle.

**Proxmox API for VM listing:** https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu
**bpg/proxmox data source (alternative — query via Terraform):** https://registry.terraform.io/providers/bpg/proxmox/latest/docs/data-sources/virtual_environment_vms

**Terraform docs:** https://registry.terraform.io/providers/bpg/proxmox/latest/docs

---

## Layer 2: Configuration — Ansible

### What Ansible does here
After Terraform creates VMs, Ansible:
1. Configures the OS (sets hostname, installs packages, disables swap)
2. Installs container runtime (containerd)
3. Installs kubeadm, kubelet, kubectl
4. On control plane: runs `kubeadm init`, generates join token
5. On workers: runs `kubeadm join` with the token from the control plane

### Dynamic Inventory
Ansible needs to know the IP addresses of newly created VMs.
Terraform outputs these IPs → write them to a file → Ansible reads it.

Two patterns:
- **Terraform output → `inventory.ini` file** (simpler): Terraform local-exec writes IPs to a file Ansible reads
- **Terraform output → Ansible dynamic inventory plugin** (cleaner at scale): Use the `community.general.proxmox` inventory plugin

### Ansible Playbook Structure
```
ansible/
├── inventory/
│   ├── hosts.ini          ← static or Terraform-generated
│   └── group_vars/
│       ├── all.yml        ← common vars (k8s version, pod CIDR)
│       ├── controlplane.yml
│       └── workers.yml
├── roles/
│   ├── common/            ← OS prep, swap off, kernel modules
│   ├── containerd/        ← container runtime install
│   ├── kubeadm/           ← kubeadm + kubelet install
│   ├── controlplane/      ← kubeadm init, kubeconfig setup
│   └── worker/            ← kubeadm join
└── site.yml               ← master playbook that calls all roles
```

### Key Ansible Galaxy Collections
- `kubernetes.core` — for interacting with k8s API from Ansible
- `community.general` — Proxmox inventory plugin

**Ansible for Kubernetes guide:** https://docs.ansible.com/ansible/latest/collections/kubernetes/core/

---

## Layer 3: Kubernetes Distribution Choice

### Option A — kubeadm (Recommended for your goals)

**Why it fits your AWS career path:**
- kubeadm is the upstream Kubernetes bootstrap tool — EKS nodes use the same kubelet/kubeadm internals under the hood
- Understanding kubeadm deeply (PKI, etcd, control plane components) directly maps to what AWS interviews and SysEng roles test
- You will manually encounter: etcd, kube-apiserver, kube-scheduler, kube-controller-manager, kubelet, kube-proxy — exactly the components AWS documentation refers to

**Trade-offs:**
| Pros | Cons |
|---|---|
| Best learning depth, maps 1:1 to AWS/CKA | More Ansible steps to set up |
| Full control over every component | etcd backup/restore is your responsibility |
| Industry standard for self-managed clusters | No built-in ingress or LB (need to add separately) |

**Set up:**
1. Ansible installs `kubeadm`, `kubelet`, `kubectl` from Kubernetes apt repo
2. Ansible runs `kubeadm init --pod-network-cidr=10.244.0.0/16` on control plane
3. Ansible captures the join command and runs it on each worker
4. Install CNI (Flannel or Calico) via kubectl apply

**kubeadm docs:** https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/

---

### Option B — k3s

**Trade-offs:**
| Pros | Cons |
|---|---|
| Single binary, minimal Ansible steps | Hides internals (embedded etcd, traefik) |
| Built-in ingress, service LB (klipper) | Less preparation for EKS/CKA concepts |
| Great for homelab | Diverges from upstream in subtle ways |

**When to choose:** If you want something running fast and don't need the learning depth right now. Good as a second cluster for experimenting with workloads.

---

### Option C — Talos Linux

**Trade-offs:**
| Pros | Cons |
|---|---|
| Immutable OS, no SSH, max security | Steep learning curve, no shell on nodes |
| Excellent for CKS (security) study | Requires `talosctl` not Ansible |
| Full kubeadm-level component exposure | Least blog/tutorial coverage |

**When to choose:** After you're comfortable with kubeadm and want to explore security hardening.

---

**Recommendation:** Start with **kubeadm**. It will teach you the most relevant skills for your AWS path and is what CKA/CKS exams test.

---

## Layer 4: GitOps — Flux vs ArgoCD

Both watch a Git repo and reconcile the cluster state to match what's in Git.
The difference is philosophy and tooling surface.

### ArgoCD

**Philosophy:** "Application-centric GitOps" — you define `Application` CRDs that point to a Git path.

**Key features:**
- Web UI (dashboard showing sync status of every app)
- Multi-cluster support built-in
- Rollback via UI
- SSO integration (OIDC/LDAP)

**Trade-offs:**
| Pros | Cons |
|---|---|
| Excellent visibility alongside Grafana | Heavier (runs its own Redis, Dex, repo-server) |
| Great for multi-cluster (matches AWS multi-region) | More complex RBAC model |
| Strong AWS/enterprise adoption | UI can become a crutch (less pure GitOps) |

**Learning value for AWS:** High — ArgoCD is widely used on EKS, and its Application model maps well to how teams organise multi-account AWS deployments.

**Install:** Helm chart or raw manifests, deploys to `argocd` namespace
**Docs:** https://argo-cd.readthedocs.io/en/stable/

---

### Flux

**Philosophy:** "Pure pull-based GitOps" — controllers watch Git and apply Kustomizations.

**Key features:**
- No UI by default (use Weave GitOps UI as an add-on)
- `HelmRelease`, `Kustomization`, `GitRepository` CRDs
- Strong Helm and Kustomize integration
- `flux bootstrap` sets up everything including its own Git repo management

**Trade-offs:**
| Pros | Cons |
|---|---|
| Lightweight, less cluster overhead | No built-in dashboard |
| Extremely composable with Kustomize | Steeper initial mental model |
| Better for "everything is a file" purists | Less enterprise tooling around it |

**Learning value for AWS:** Medium-high — used on EKS but less dominant than ArgoCD in enterprise. Great for understanding pure GitOps principles.

**Install:** `flux bootstrap github` wires it directly to your GitHub repo
**Docs:** https://fluxcd.io/flux/

---

### Recommendation for your setup
Use **ArgoCD** as your primary GitOps operator. The UI gives you visual feedback while learning, it pairs naturally with Grafana dashboards, and it has the best AWS/enterprise parallel. Add Flux later if you want to learn both — they can coexist in separate namespaces.

---

## Layer 5: Monitoring — Prometheus + Grafana + AlertManager

### Stack
- **Prometheus** — scrapes metrics from nodes and pods
- **AlertManager** — receives Prometheus alerts, routes them to webhooks
- **Grafana** — dashboards for cluster and node metrics
- **node-exporter** — runs as a DaemonSet, exposes per-VM metrics (RAM, CPU, disk)
- **kube-state-metrics** — exposes Kubernetes object state (pod count, node status)

### Install Method
Use the **kube-prometheus-stack** Helm chart — it bundles all of the above.

```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring
```

**Chart docs:** https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

### Key Prometheus Metric for Scaling Decision
```promql
# Per-node memory used (bytes)
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes

# As a percentage
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
```

### AlertManager → GitHub Actions Webhook

This is the bridge between monitoring and your GitHub Actions workflows. There are no manual triggers — every action is driven by Prometheus metrics.

**Three alert rules to define:**

| Alert Rule | Condition | Fires → |
|---|---|---|
| `NodeMemoryPressure` | Worker RAM usage > 75% for >5 min | `repository_dispatch` type `memory-pressure` |
| `NodeMemoryLow` | Worker RAM usage < 30% for >15 min | `repository_dispatch` type `scale-in` |
| `ClusterHighLoad` | All workers above 75% RAM simultaneously | `repository_dispatch` type `scale-out` (bypass resize, go straight horizontal) |

**Key PromQL for each:**
```promql
# Memory pressure per node (>75%)
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 75

# Memory underutilised per node (<30%) — candidate for removal
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 30

# All workers simultaneously under pressure — skip vertical, go horizontal immediately
count(
  (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 75
) == count(kube_node_info{role="worker"})
```

**AlertManager config structure (yaml):**
```yaml
route:
  receiver: 'default'
  routes:
    - match:
        alertname: NodeMemoryPressure
      receiver: 'memory-pressure-hook'
    - match:
        alertname: NodeMemoryLow
      receiver: 'scale-in-hook'
    - match:
        alertname: ClusterHighLoad
      receiver: 'scale-out-hook'

receivers:
  - name: 'memory-pressure-hook'
    webhook_configs:
      - url: 'https://api.github.com/repos/<owner>/<repo>/dispatches'
        http_config:
          authorization:
            credentials: '<github-pat-or-app-token>'
        send_resolved: false
        # body must include: {"event_type": "memory-pressure", "client_payload": {"node": "<nodename>"}}
  - name: 'scale-in-hook'
    webhook_configs:
      - url: 'https://api.github.com/repos/<owner>/<repo>/dispatches'
        http_config:
          authorization:
            credentials: '<github-pat-or-app-token>'
        send_resolved: false
        # body must include: {"event_type": "scale-in", "client_payload": {"node": "<nodename>"}}
  - name: 'scale-out-hook'
    webhook_configs:
      - url: 'https://api.github.com/repos/<owner>/<repo>/dispatches'
        http_config:
          authorization:
            credentials: '<github-pat-or-app-token>'
        send_resolved: false
        # body must include: {"event_type": "scale-out"}
```

> AlertManager's `webhook_config` sends a fixed JSON body — it cannot natively template `client_payload`. You will need a small intermediary (e.g. a Kubernetes Job triggered by AlertManager, or a webhook adapter like `alertmanager-webhook-adapter`) to enrich the payload with the node name before forwarding to GitHub.

**AlertManager docs:** https://prometheus.io/docs/alerting/latest/configuration/
**GitHub repository_dispatch docs:** https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event
**alertmanager-webhook-adapter:** https://github.com/prometheus-community/alertmanager-webhook-adapter

---

## Layer 6: The Three GitHub Actions Workflows

This section describes what each workflow does at a logical level so you can build them. **No manual triggers** — all workflows are driven exclusively by AlertManager `repository_dispatch` events.

### Workflow 1: Deploy Worker

**Trigger:** `repository_dispatch` event type `scale-out` (fired by AlertManager `ClusterHighLoad` alert)

**Steps:**
1. Checkout repo
2. Authenticate to Terraform state backend
3. **Run placement selection** (before any Terraform call):
   - Read `terraform/node_capacities.json`
   - Query Proxmox API `GET /nodes/{node}/qemu` for each node
   - Count worker VMs per node (filter by name pattern)
   - Calculate remaining capacity per node
   - Select node with highest remaining; fail if all nodes are at max
4. Derive the new worker name: `worker-{selected_node}-{next_sequence}`
   - Next sequence = current highest sequence on that node + 1
5. Run `terraform apply` passing the updated workers map (new entry added with selected node and default memory/cores)
   - Terraform creates the VM on the selected Proxmox node
   - Outputs the new VM's IP address
6. Run Ansible `site.yml` targeting only the new VM
7. Verify node is `Ready` via `kubectl get nodes`

---

### Workflow 2: Remove Worker

**Trigger:** `repository_dispatch` event type `scale-in` (fired by AlertManager `NodeMemoryLow` alert — node sustained below 30% RAM for >15 min)

**Steps:**
1. Checkout repo
2. Read node name from `client_payload.node` (passed by AlertManager webhook adapter)
3. Confirm node is still underutilised — re-query Prometheus before acting (guard against stale alert)
4. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
5. `kubectl delete node <node>`
6. Run `terraform apply` with `worker_count - 1`, targeting the specific VM by name
7. Verify node no longer appears in `kubectl get nodes`

> **Always drain before destroy.** Destroying the VM first leaves a `NotReady` node object and orphans running pods.
> **Always re-check Prometheus before acting.** AlertManager can fire on transient dips — a short re-query prevents removing a node that has recovered.

---

### Workflow 3: Resize Worker (Vertical Scale Decision Gate)

**Trigger:** `repository_dispatch` event type `memory-pressure` (fired by AlertManager `NodeMemoryPressure` alert — single node above 75% RAM for >5 min)

**Decision logic:**
```
Read node name from client_payload.node

Query Terraform state → what is the current memory allocation (GB) for this VM?

IF current_allocated_ram < 16 GB:
    → Vertical scale path: increase RAM for this specific VM

ELSE (current_allocated_ram >= 16 GB — vertical cap hit):
    → Re-fire scale-out: trigger Deploy Worker workflow
      (all workers are already at max vertical size, must go horizontal)
```

**Vertical scale path steps:**
1. `kubectl cordon <node>` — stop new pods scheduling here
2. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
3. `terraform apply` — increase `memory` on that specific VM (e.g. 8 GB → 12 GB → 16 GB in steps)
4. Wait for VM to come back up and node to return `Ready`
5. `kubectl uncordon <node>`

**Proxmox note:** QEMU guest agent + memory ballooning can allow hot-add without reboot, but this requires the balloon driver to be installed in the VM and configured in Proxmox. Don't rely on it — always plan for the cordon/drain/resize/reboot/rejoin cycle as the safe path.

**Scale step size:** Define a fixed increment (e.g. +4 GB per trigger). This prevents a single alert from jumping a node straight to 16 GB when a smaller bump would resolve the pressure.

---

## Layer 7: Terraform State Backend Options

Terraform state is a JSON file that tracks what resources exist. It **must not live in Git** (contains secrets) and **must be locked** when CI/CD runs so two workflows don't conflict.

### Option A — Terraform Cloud / HCP (Recommended for your setup)

**How it works:** State is stored in HashiCorp's cloud. GitHub Actions authenticates via OIDC (no stored secrets). Free tier covers 1 workspace / 500 resources.

**Pros:**
- Zero infrastructure to manage
- Built-in state locking
- OIDC auth = no long-lived tokens in GitHub Secrets
- Remote execution possible (runs Terraform in HCP, not GitHub runner)
- Maps to how AWS CDK/CloudFormation state is managed (externally, not in repo)

**Cons:**
- External dependency (not fully self-hosted)
- Free tier has limits; paid tier is expensive

**Docs:** https://developer.hashicorp.com/terraform/cloud-docs

---

### Option B — MinIO on Proxmox (S3-compatible self-hosted)

**How it works:** Run a MinIO VM/container on your Proxmox node. Configure Terraform S3 backend pointing to MinIO. GitHub Actions authenticates with MinIO access key stored in GitHub Secrets.

**Pros:**
- Fully self-hosted — no external dependency
- S3 API-compatible — directly maps to how AWS S3 backend is used in real AWS environments (excellent learning parallel)
- DynamoDB-style locking via a separate table is not needed — MinIO supports S3 object locking for state

**Cons:**
- You manage MinIO availability (if it goes down, Terraform can't run)
- Need to set up MinIO separately before the k8s cluster exists (chicken-and-egg: run it outside the cluster)
- Access keys need rotating

**S3 backend docs:** https://developer.hashicorp.com/terraform/language/backend/s3
**MinIO quickstart:** https://min.io/docs/minio/linux/index.html

---

### Option C — Local file (dev/solo only)

**How it works:** State lives as `terraform.tfstate` on whatever machine runs Terraform — in this case, the GitHub Actions runner (ephemeral).

**Critical problem:** GitHub Actions runners are ephemeral. The state file is destroyed after every run. On the next run, Terraform has no memory of what it created and will try to recreate everything.

**When acceptable:** Running Terraform locally from your own machine as a one-off. Never in CI/CD.

---

### Recommendation
**Start with Terraform Cloud** (free tier is sufficient, OIDC integration is clean, no extra VM to manage).
**Migrate to MinIO S3 backend** once your cluster is stable — it gives you the best AWS parallel for learning and keeps everything self-hosted.

---

## Layer 8: Networking Considerations

### CNI (Container Network Interface)
Must be installed after `kubeadm init`. Two common choices:

| CNI | Best for |
|---|---|
| **Flannel** | Simple overlay, minimal config, good for learning |
| **Calico** | Network policies, eBPF support, closer to AWS VPC CNI behaviour |

Recommendation: **Calico** — it supports Kubernetes NetworkPolicy objects (tested on CKA/CKS) and its architecture maps to how AWS VPC CNI works.

**Calico docs:** https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises

### Ingress
Install **ingress-nginx** or **Traefik** to expose services externally. On Proxmox (bare metal), you also need a **MetalLB** load balancer to assign real IPs to `LoadBalancer`-type Services.

**MetalLB docs:** https://metallb.universe.tf/

---

## Layer 9: Repository Structure (Full Picture)

```
repo/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── controlplane.tf
│   ├── worker.tf
│   └── versions.tf
│
├── ansible/
│   ├── inventory/
│   │   ├── hosts.ini
│   │   └── group_vars/
│   ├── roles/
│   │   ├── common/
│   │   ├── containerd/
│   │   ├── kubeadm/
│   │   ├── controlplane/
│   │   └── worker/
│   └── site.yml
│
├── k8s/                          ← GitOps watched directory
│   ├── namespaces/
│   ├── monitoring/               ← kube-prometheus-stack HelmRelease
│   ├── ingress/                  ← ingress-nginx / MetalLB
│   └── apps/                     ← your workloads
│
├── argocd/                       ← ArgoCD Application definitions
│   └── apps/
│       ├── monitoring.yaml
│       └── ingress.yaml
│
└── .github/
    └── workflows/
        ├── deploy-worker.yml
        ├── remove-worker.yml
        └── resize-worker.yml
```

---

## Layer 10: Build Sequence (Order of Operations)

This is the order to build things so each layer has its dependencies ready:

```
1. Proxmox setup
   └── Create VM template (Ubuntu cloud image)
   └── Enable Proxmox API token for Terraform

2. Terraform state backend
   └── Set up Terraform Cloud workspace OR MinIO VM

3. Terraform — control plane VM
   └── Apply once manually to create control plane VM

4. Ansible — control plane configuration
   └── Run site.yml against control plane
   └── Verify `kubectl get nodes` shows control plane Ready

5. Terraform — first worker VM
   └── Apply with worker_count=1

6. Ansible — worker configuration
   └── Run site.yml against worker
   └── Verify worker joins cluster

7. CNI installation
   └── kubectl apply Calico manifests

8. Monitoring stack
   └── Helm install kube-prometheus-stack
   └── Configure AlertManager webhook receiver

9. GitOps operator
   └── ArgoCD install (Helm or manifests)
   └── Create ArgoCD Application pointing to k8s/ directory
   └── Verify ArgoCD syncs monitoring and ingress

10. GitHub Actions workflows
    └── Store secrets: Proxmox API token, kubeconfig, TF Cloud token, GitHub PAT
    └── Deploy webhook adapter (intermediary between AlertManager and GitHub)

11. AlertManager → GitHub Actions bridge
    └── Configure alert rules: NodeMemoryPressure, NodeMemoryLow, ClusterHighLoad
    └── Configure webhook_config receivers → webhook adapter → repository_dispatch
    └── End-to-end test: run stress-ng on a worker node → confirm alert fires
       → confirm repository_dispatch received → confirm correct workflow runs
```

---

## Key Resources Reference

| Topic | Resource |
|---|---|
| Proxmox Terraform provider | https://registry.terraform.io/providers/bpg/proxmox/latest/docs |
| Proxmox cloud-init | https://pve.proxmox.com/wiki/Cloud-Init_Support |
| Proxmox API docs | https://pve.proxmox.com/pve-docs/api-viewer/ |
| kubeadm install guide | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/ |
| kubeadm HA setup | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/ |
| Ansible kubernetes.core | https://docs.ansible.com/ansible/latest/collections/kubernetes/core/ |
| Calico CNI | https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises |
| MetalLB | https://metallb.universe.tf/installation/ |
| ArgoCD getting started | https://argo-cd.readthedocs.io/en/stable/getting_started/ |
| Flux getting started | https://fluxcd.io/flux/get-started/ |
| kube-prometheus-stack | https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack |
| Prometheus AlertManager config | https://prometheus.io/docs/alerting/latest/configuration/ |
| GitHub repository_dispatch | https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event |
| Terraform Cloud OIDC | https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials |
| Terraform S3 backend | https://developer.hashicorp.com/terraform/language/backend/s3 |
| MinIO quickstart | https://min.io/docs/minio/linux/index.html |
| KEDA (alternative scaling) | https://keda.sh/docs/latest/scalers/prometheus/ |

---

## Certification / Learning Path Note

Since you're targeting AWS Systems Engineer roles, this stack gives you direct practice for:
- **CKA (Certified Kubernetes Administrator)** — kubeadm, cluster upgrades, etcd backup, networking
- **CKS (Certified Kubernetes Security Specialist)** — network policies (Calico), RBAC, audit logs
- **AWS EKS** — kubeadm internals map directly; ArgoCD is widely deployed on EKS
- **Terraform Associate** — state management, modules, providers, remote backends
- **GitOps patterns** — ArgoCD Application model matches how AWS DevOps teams deploy to EKS

The Proxmox + kubeadm setup intentionally exposes every component you'd normally never see in a managed service, which is exactly the depth AWS SysEng interviews probe.
