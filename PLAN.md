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
- Fixed CPU/RAM (e.g. 4 CPU, 8 GB RAM)

**Worker VM** (dynamic — this is what deploy/remove/resize actions target):
- `proxmox_virtual_environment_vm.worker` with `count` or `for_each`
- Parameterised: `var.worker_count`, `var.worker_memory`, `var.worker_cores`

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

This is the bridge between monitoring and your GitHub Actions workflows.

1. Define a Prometheus alert rule (e.g. `NodeMemoryHighUtilisation`) that fires when a worker node's RAM usage is above a threshold for >5 minutes
2. AlertManager routes that alert to a `webhook_config` receiver
3. The webhook URL points to a GitHub Actions `repository_dispatch` endpoint
4. GitHub Actions receives the payload, inspects the node name and current VM RAM allocation, and decides: vertical or horizontal scale

**AlertManager webhook config example (yaml — not a GitHub Actions file):**
```yaml
receivers:
  - name: 'scale-trigger'
    webhook_configs:
      - url: 'https://api.github.com/repos/<owner>/<repo>/dispatches'
        http_config:
          authorization:
            credentials: '<github-pat-or-app-token>'
        send_resolved: false
```

**AlertManager docs:** https://prometheus.io/docs/alerting/latest/configuration/
**GitHub repository_dispatch docs:** https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event

---

## Layer 6: The Three GitHub Actions Workflows

You said you don't want me to build the files — this section describes what each workflow does at a logical level so you can build them.

### Workflow 1: Deploy Worker

**Trigger:** Manual (`workflow_dispatch`) or `repository_dispatch` event type `scale-out`

**Steps:**
1. Checkout repo
2. Authenticate to Terraform state backend (see Layer 7)
3. Run `terraform apply` with incremented `worker_count` var
   - Terraform creates a new Proxmox VM from template
   - Outputs the new VM's IP address
4. Run Ansible `site.yml` targeting only the new VM
   - Configures OS, installs k8s, runs `kubeadm join`
5. Verify node is `Ready` via `kubectl get nodes`
6. (Optional) Push a commit to the GitOps repo to record the new node in state

**Key inputs:** `worker_count` (new desired total), or derive it from current count + 1

---

### Workflow 2: Remove Worker

**Trigger:** Manual (`workflow_dispatch`) or `repository_dispatch` event type `scale-in`

**Steps:**
1. Checkout repo
2. Select the worker node to remove (pass as input, or select least-loaded via Prometheus query)
3. Run `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
   - Safely evicts all pods before removal
4. Run `kubectl delete node <node>`
5. Run `terraform apply` with decremented `worker_count`
   - Terraform destroys the matching Proxmox VM
6. Verify node no longer appears in `kubectl get nodes`

**Important:** Always drain before destroy. Destroying the VM first will leave the node object in `NotReady` state and orphan any running pods.

---

### Workflow 3: Resize Worker (Vertical Scale Decision Gate)

**Trigger:** `repository_dispatch` event type `memory-pressure` (from AlertManager webhook)

**The decision logic (describe in your workflow):**
```
Query Prometheus: What is the current RAM allocation (in GB) for the affected worker VM?
  → Terraform state / Proxmox API

IF current_ram < 16 GB:
    Run terraform apply with increased memory for that VM
    (Proxmox supports hot-plug memory changes on QEMU VMs if configured)
    OR: gracefully restart the VM with new RAM setting (brief downtime, drain first)
ELSE (current_ram >= 16 GB):
    Trigger the Deploy Worker workflow (scale-out event)
    (We've hit the vertical cap — must go horizontal)
```

**Steps for vertical resize path:**
1. Drain the target worker (or use hot-plug if Proxmox QEMU agent is configured)
2. Run `terraform apply` targeting only that VM with new `memory` value
3. Wait for node to return `Ready`
4. Uncordon: `kubectl uncordon <node>`

**Key Proxmox capability to know:** QEMU guest agent + memory ballooning allows some memory changes without full reboot — but this is Proxmox-specific configuration, not guaranteed. Plan for a cordon/drain/resize/reboot/rejoin cycle to be safe.

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
    └── Store Proxmox API token, kubeconfig, TF Cloud token in GitHub Secrets
    └── Test deploy-worker workflow manually
    └── Test remove-worker workflow manually
    └── Test resize-worker workflow manually (with a low RAM threshold to trigger it)

11. AlertManager → GitHub Actions bridge
    └── Configure webhook receiver in AlertManager
    └── Create test alert to verify repository_dispatch fires correctly
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
