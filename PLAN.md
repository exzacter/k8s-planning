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

### Proxmox VM Template (automated via Packer)
Before Terraform can clone VMs you need a base template. This is handled by **Packer**, not manually.
Packer's `proxmox-iso` builder:
1. Downloads the Ubuntu 24.04 cloud image directly onto Proxmox
2. Creates a VM, boots it, and runs a provisioner script (installs `qemu-guest-agent`, disables swap)
3. Converts the VM to a Proxmox template automatically

The Packer template lives in `packer/ubuntu-2404.pkr.hcl` in the repo and is run once from the developer machine before any Terraform is applied. If the template needs rebuilding (OS updates), re-run Packer.

**Packer proxmox builder:** https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox
**Proxmox cloud-init reference:** https://pve.proxmox.com/wiki/Cloud-Init_Support

### Terraform File Structure
```
terraform/
├── main.tf              ← provider config
├── variables.tf         ← CP specs, worker defaults, VIP address
├── outputs.tf           ← CP IPs, VIP, worker IPs passed to Ansible
├── controlplane.tf      ← 3 CP VM resources (for_each over pve1/pve2/pve3)
├── worker.tf            ← worker VM resources (for_each over workers map)
├── node_capacities.json ← pve1/pve2/pve3 worker capacity; pve4 workers-only
└── versions.tf          ← provider version pins
```

### Key Terraform Resources to Define

**Control plane VMs** (static — three VMs for HA, never auto-scaled):
- `proxmox_virtual_environment_vm.controlplane` as a `for_each` over a map of three entries: one per control plane node
- One VM on each of **pve1, pve2, pve3** — pve4 is reserved exclusively for workers
- Fixed CPU/RAM per VM (e.g. 2 CPU, 4 GB RAM each — smaller than a single fat CP since there are three)
- A **keepalived VIP** (virtual IP, also a VM or static configuration on Proxmox) provides a single stable endpoint for the Kubernetes API server — kubeadm is initialised with `--control-plane-endpoint <VIP>:6443`
- kubeadm initialises the first CP node (`controlplane-pve1`), then the other two join with `kubeadm join --control-plane` — this forms a stacked etcd HA cluster (etcd runs on each CP node)
- 4 static IPs required: 3 CP VMs + 1 VIP

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

**Node capacity and IP config** — stored in `terraform/node_capacities.json` (tracked in Git):

```json
{
  "pve1": { "max_workers": 3, "worker_ip_start": "192.168.1.100", "worker_ip_end": "192.168.1.102" },
  "pve2": { "max_workers": 6, "worker_ip_start": "192.168.1.110", "worker_ip_end": "192.168.1.115" },
  "pve3": { "max_workers": 4, "worker_ip_start": "192.168.1.120", "worker_ip_end": "192.168.1.123" },
  "pve4": { "max_workers": 2, "worker_ip_start": "192.168.1.130", "worker_ip_end": "192.168.1.131" }
}
```

Each node gets its own non-overlapping IP range sized to its max worker count. The ranges sit inside the DHCP exclusion zone you configure in your router (Step 1.5) so nothing else on the LAN can claim them.

Control plane static IPs and the keepalived VIP are defined separately in `terraform/variables.tf` as hardcoded defaults — they never change after initial setup.

**IP selection (runs in the deploy-worker workflow, before Terraform):**
1. Read `node_capacities.json` — get the `worker_ip_start` and `worker_ip_end` for the selected node
2. Read the current workers map from Terraform state (`terraform show -json`) — collect all IPs already assigned to workers on that node
3. Walk the IP range from `worker_ip_start` upward — take the first IP not already present in the workers map
4. That IP becomes the `ip` field in the new workers map entry passed to `terraform apply`

Terraform never picks IPs — it receives a complete entry and creates the VM with that exact IP injected via cloud-init. The workflow is the source of truth for IP assignment.

**Resulting workers map in Terraform state (example):**
```json
{
  "worker-pve2-01": { "node": "pve2", "memory": 4096, "cores": 2, "ip": "192.168.1.110" },
  "worker-pve2-02": { "node": "pve2", "memory": 4096, "cores": 2, "ip": "192.168.1.111" },
  "worker-pve1-01": { "node": "pve1", "memory": 4096, "cores": 2, "ip": "192.168.1.100" }
}
```

When a worker is removed, its IP is freed — the next deploy on that node will reuse it (lowest available in range).

**Placement algorithm (runs in the deploy-worker workflow, immediately before IP selection):**
1. Read `node_capacities.json` from the repo
2. Query the Proxmox API for each node: `GET /api2/json/nodes/{node}/qemu` — returns all VMs on that node
3. Filter the response to count only VMs whose names match the worker naming pattern (`worker-{node}-*`)
4. For each node: calculate `remaining = max_workers - current_worker_count`
5. Select the node with the **highest remaining capacity**
6. Tiebreak rule: if two nodes have equal remaining capacity, prefer the one with the higher `max_workers` value (it has more headroom overall)
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
4. On the first control plane node (`controlplane-pve1`): runs `kubeadm init --control-plane-endpoint <VIP>:6443 --upload-certs`, captures the certificate key and join command
5. On the second and third control plane nodes (`controlplane-pve2`, `controlplane-pve3`): runs `kubeadm join <VIP>:6443 --control-plane --certificate-key <key>`
6. On workers: runs `kubeadm join <VIP>:6443` with the worker join token

### Dynamic Inventory
Ansible needs to know the IP addresses of newly created VMs.
Terraform outputs these IPs → write them to a file → Ansible reads it.

The inventory is generated in the bootstrap workflow (and scaling workflows) using `terraform output -json | jq` to extract IP addresses and write a `hosts.ini` file on the runner before Ansible runs. The `inventory/` directory is gitignored — it only exists at runtime on the runner.

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
│   ├── keepalived/        ← VIP setup, runs on all three CP VMs before kubeadm
│   ├── controlplane/      ← kubeadm init on primary CP (pve1), captures cert key + join cmd
│   ├── controlplane-join/ ← kubeadm join --control-plane for secondary CPs (pve2, pve3)
│   └── worker/            ← kubeadm join (worker token)
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
2. Ansible configures keepalived on all 3 CP nodes (VIP floats between them)
3. Ansible runs `kubeadm init --control-plane-endpoint <VIP>:6443 --upload-certs --pod-network-cidr=192.168.0.0/16` on the primary CP node (pve1)
4. Ansible runs `kubeadm join <VIP>:6443 --control-plane --certificate-key <key>` on pve2 and pve3
5. Ansible captures the worker join command and runs it on each worker node
6. Install Calico CNI via `kubectl apply` (pod CIDR must be `192.168.0.0/16` to match the init flag)

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
- **Grafana** — dashboards, logs, and traces in one UI
- **node-exporter** — DaemonSet exposing per-VM metrics (RAM, CPU, disk)
- **kube-state-metrics** — exposes Kubernetes object state (pod count, node status)
- **Loki** — log aggregation store; receives logs from Promtail
- **Promtail** — DaemonSet log collector; ships container and system logs from every node to Loki
- **prometheus-pve-exporter** — scrapes the Proxmox API and exposes hypervisor-level metrics (Proxmox node CPU/RAM, VM power state, storage pool free space) to Prometheus; gives visibility into the layer below Kubernetes

### Install Method
Use the **kube-prometheus-stack** Helm chart — it bundles all of the above.
Deployed via an **ArgoCD `Application` manifest** committed to `k8s/monitoring/` — not a manual `helm install`. ArgoCD installs and manages the chart automatically once the bootstrap workflow runs.
Grafana dashboards (Node Exporter Full, Kubernetes Overview) are provisioned automatically via a `ConfigMap` — no manual dashboard import needed.

**Chart docs:** https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
**Grafana provisioning:** https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards

### Key Prometheus Metric for Scaling Decision
```promql
# Per-node memory used (bytes)
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes

# As a percentage
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
```

### AlertManager → GitHub Actions Webhook

This is the bridge between monitoring and your GitHub Actions workflows. There are no manual triggers — every action is driven by Prometheus metrics. Scaling alerts cover all stretchable resources: RAM, CPU, and disk I/O.

**Alert rules to define:**

| Alert Rule | Condition | Fires → |
|---|---|---|
| `NodeMemoryPressure` | Single worker RAM > 75% for >5 min | `repository_dispatch` type `resource-pressure`, metric=`memory` |
| `NodeCPUPressure` | Single worker CPU > 80% for >5 min | `repository_dispatch` type `resource-pressure`, metric=`cpu` |
| `NodeDiskPressure` | Single worker root disk > 80% for >5 min | `repository_dispatch` type `resource-pressure`, metric=`disk` |
| `NodeUnderutilised` | Single worker RAM < 30% **and** CPU < 20% for >15 min | `repository_dispatch` type `scale-in` |
| `ClusterHighLoad` | All workers above 75% RAM **or** all workers above 80% CPU simultaneously | `repository_dispatch` type `scale-out` (bypass resize, go straight horizontal) |

The `resource-pressure` event type replaces the former `memory-pressure` — the `metric` field in `client_payload` tells the resize-worker workflow what resource triggered and informs its vertical scale decision (e.g. adding CPU vs RAM). Scale-in now requires **both** RAM and CPU to be low — a node that is CPU-bound but RAM-idle must not be removed.

**Key PromQL for each:**
```promql
# RAM pressure per node (>75%)
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 75

# CPU pressure per node (>80%) — 5-minute rate smooths spikes
100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80

# Disk pressure per node root filesystem (>80%)
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 > 80

# Node underutilised — both RAM and CPU below threshold
(
  (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 30
) and (
  100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) < 20
)

# All workers simultaneously under RAM pressure — skip vertical, go horizontal immediately
count(
  (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 75
) == count(kube_node_info{role="worker"})

# All workers simultaneously under CPU pressure — same: go horizontal immediately
count(
  100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
) == count(kube_node_info{role="worker"})
```

**AlertManager config structure (yaml):**
```yaml
route:
  receiver: 'default'
  routes:
    - match_re:
        alertname: 'Node(Memory|CPU|Disk)Pressure'
      receiver: 'resource-pressure-hook'
    - match:
        alertname: NodeUnderutilised
      receiver: 'scale-in-hook'
    - match:
        alertname: ClusterHighLoad
      receiver: 'scale-out-hook'

receivers:
  - name: 'resource-pressure-hook'
    webhook_configs:
      - url: 'http://alertmanager-webhook-adapter.monitoring.svc/webhook'
        send_resolved: false
        # adapter enriches payload with node label and metric name before forwarding to GitHub
  - name: 'scale-in-hook'
    webhook_configs:
      - url: 'http://alertmanager-webhook-adapter.monitoring.svc/webhook'
        send_resolved: false
  - name: 'scale-out-hook'
    webhook_configs:
      - url: 'http://alertmanager-webhook-adapter.monitoring.svc/webhook'
        send_resolved: false
```

> AlertManager's `webhook_config` cannot natively template `client_payload`. The `alertmanager-webhook-adapter` handles translation: it receives the AlertManager payload, extracts the node label and alertname, maps them to a GitHub `repository_dispatch` event, and forwards to the GitHub API.

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
3. **Run placement selection:**
   - Read `terraform/node_capacities.json`
   - Query Proxmox API `GET /nodes/{node}/qemu` for each node
   - Count worker VMs per node (filter by name pattern `worker-{node}-*`)
   - Calculate `remaining = max_workers - current_count` per node
   - Select node with highest remaining; fail if all nodes are at max
4. **Derive worker name:** `worker-{selected_node}-{next_sequence}`
   - Next sequence = current highest sequence on that node + 1 (zero-padded, e.g. `01`, `02`)
5. **Select IP for the new worker:**
   - Read `worker_ip_start` and `worker_ip_end` for the selected node from `node_capacities.json`
   - Run `terraform show -json` to get the current workers map from state
   - Collect all IPs already assigned to workers on this node
   - Walk the node's IP range from `worker_ip_start` upward — take the first IP not in use
6. **Build the new workers map entry:**
   ```json
   { "node": "pve2", "memory": 4096, "cores": 2, "ip": "192.168.1.111" }
   ```
   Add it to the existing workers map under the new worker name
7. Run `terraform apply` passing the complete updated workers map
   - Terraform clones the template, injects the IP via cloud-init, starts the VM
   - The VM boots and configures itself (hostname, SSH key, static IP) — no GUI, no interaction
8. Generate a fresh kubeadm join token from the control plane VIP:
   `kubeadm token create --print-join-command` — tokens expire after 24h so always generate fresh
9. Run Ansible worker role targeting only the new VM's IP
10. Verify node appears `Ready` via `kubectl get nodes`
11. Send Discord notification (green — worker name, node, IP)

---

### Workflow 2: Remove Worker

**Trigger:** `repository_dispatch` event type `scale-in` (fired by AlertManager `NodeUnderutilised` alert — node sustained below 30% RAM **and** below 20% CPU for >15 min)

**Steps:**
1. Checkout repo
2. Read node name from `client_payload.node` (passed by AlertManager webhook adapter)
3. Confirm node is still underutilised — re-query Prometheus before acting (guard against stale alert)
4. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
5. `kubectl delete node <node>`
6. Read the current workers map from Terraform state, remove the entry for this worker, run `terraform apply` — Terraform destroys only that VM on its Proxmox node
7. Verify node no longer appears in `kubectl get nodes`

> **Always drain before destroy.** Destroying the VM first leaves a `NotReady` node object and orphans running pods.
> **Always re-check Prometheus before acting.** AlertManager can fire on transient dips — a short re-query prevents removing a node that has recovered.

---

### Workflow 3: Resize Worker (Vertical Scale Decision Gate)

**Trigger:** `repository_dispatch` event type `resource-pressure` (fired by AlertManager `NodeMemoryPressure`, `NodeCPUPressure`, or `NodeDiskPressure` — single node above threshold for >5 min)

**Decision logic:**
```
Read node name from client_payload.node
Read triggering metric from client_payload.metric (memory | cpu | disk)

Query Terraform state → what are the current resource allocations for this VM?

FOR metric = memory:
    IF current_allocated_ram < 16 GB → vertical scale path (increase RAM)
    ELSE (cap hit) → trigger Deploy Worker (scale-out)

FOR metric = cpu:
    IF current_allocated_cores < 8 cores → vertical scale path (increase vCPUs)
    ELSE (cap hit) → trigger Deploy Worker (scale-out)

FOR metric = disk:
    Disk cannot be hot-extended safely — trigger Deploy Worker (scale-out) immediately
    (disk pressure means the workload needs a new node, not a resize)
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

## Layer 6b: Notifications and Approval Gates — Discord

Notifications use three independent paths so that Discord always reflects cluster state, regardless of whether GitHub Actions is involved.

### Path A — GitHub Actions → Discord (workflow events)
Every GitHub Actions workflow sends a Discord message via a `curl` POST to `DISCORD_WEBHOOK_URL` (stored in GitHub Secrets). This path fires for actions the workflows initiate.

| Event | Colour |
|---|---|
| Workflow started | Yellow |
| Success | Green |
| Failure (link to run) | Red |
| All nodes at capacity — needs human action | Red + @here |
| Scale-in blocked — last worker | Yellow |
| Resize cap hit → triggering scale-out | Blue |

### Path B — AlertManager → Discord (cluster health events)
AlertManager sends some alerts **directly** to a Discord webhook — not via the GitHub API. This path fires for cluster-level events that have nothing to do with scaling workflows: a node goes `NotReady`, a pod enters CrashLoopBackOff, disk fills on the control plane.

These notifications arrive in Discord even if the GitHub Actions runner is down or GitHub's API is degraded.

Configuration: add a separate `discord_config` receiver in AlertManager alongside the `webhook_config` receivers. AlertManager has native Discord support via `discord_configs` in v0.25+:
```yaml
receivers:
  - name: 'cluster-health-discord'
    discord_configs:
      - webhook_url: '<DISCORD_WEBHOOK_URL>'
        title: '{{ .CommonAnnotations.summary }}'
        message: '{{ .CommonAnnotations.description }}'
```
Route non-scaling alerts (NodeNotReady, PodCrashLooping, DiskFull) to this receiver.

**AlertManager Discord receiver docs:** https://prometheus.io/docs/alerting/latest/configuration/#discord_config

### Path C — ArgoCD Notifications Controller → Discord (GitOps events)
The ArgoCD Notifications Controller runs inside the cluster and fires when an ArgoCD Application goes out-of-sync, fails to sync, or degrades in health. This catches situations like a broken k8s manifest being committed to Git — ArgoCD will attempt to sync and fail, and Discord will be notified immediately without any workflow being involved.

Configured via a `ConfigMap` in the `argocd` namespace (committed to Git, managed by ArgoCD itself):
```yaml
# argocd-notifications-cm ConfigMap
triggers:
  - name: on-sync-failed
    condition: app.status.operationState.phase in ['Error', 'Failed']
    template: app-sync-failed
templates:
  - name: app-sync-failed
    discord:
      content: "ArgoCD sync failed: {{.app.metadata.name}}"
```
Reference: https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/

**Discord webhook reference:** https://discord.com/developers/docs/resources/webhook#execute-webhook
**Embed format (colour-coded messages):** https://discord.com/developers/docs/resources/message#embed-object

### Two-Way Approval Gates

For blocked conditions (all nodes at capacity, last-worker scale-in protection), automation pauses and waits for human decision.

**Option A — GitHub Environments (recommended starting point):**
A `manual-review` environment is configured in GitHub repo settings with required reviewers. When triggered, the workflow pauses and a Discord notification is sent with the direct GitHub approval URL. The reviewer clicks the link from Discord and approves/rejects on GitHub. Zero extra infrastructure.
Reference: https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment

**Option B — Discord Bot with Button Interactions (in-Discord yes/no):**
A Discord Application + Bot deployed as a k8s Deployment inside the cluster. Blocked events send a message with Yes/No buttons directly in Discord. Button clicks are received by the bot's interactions endpoint (exposed publicly via Cloudflare Tunnel — no port forwarding needed), which forwards the decision to GitHub via `repository_dispatch`.
- Discord Application setup: https://discord.com/developers/applications
- Cloudflare Tunnel (public HTTPS without port forwarding): https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- Discord Interactions reference: https://discord.com/developers/docs/interactions/overview

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

## Layer 7c: Secrets Management — OpenBao + External Secrets Operator

### Why not GitHub Secrets alone
Every secret in GitHub Secrets is scoped to the repo and grants full access to anyone who can access Settings. The Proxmox API token in GitHub Secrets can create and destroy VMs; the kubeconfig grants cluster-admin. There is no audit log, no rotation mechanism, and k8s Secrets in etcd are base64-encoded — not encrypted at rest by default.

### OpenBao
OpenBao is the open-source fork of HashiCorp Vault, created after Vault's BSL license change in August 2023. It is maintained under the Linux Foundation (same governance as OpenTofu), MPL-2.0 licensed, and API-compatible with Vault — same CLI, same k8s auth method, same AWS Secrets Manager conceptual parallel.

OpenBao runs as a standalone VM on Proxmox (outside the k8s cluster — same as MinIO) so it survives cluster rebuilds.

Key features used here:
- **k8s auth method** — pods authenticate to OpenBao using their ServiceAccount token; no static credentials needed inside the cluster
- **Static secrets engine** (`kv-v2`) — stores all project credentials (Proxmox token, GitHub PAT, Discord webhook, MinIO keys) with versioning
- **Audit log** — every secret read is recorded

### External Secrets Operator (ESO)
ESO is a k8s operator that reads secrets from OpenBao and syncs them into standard k8s Secrets automatically. ArgoCD manages the ESO deployment and `ExternalSecret` CRD definitions.

```
OpenBao (Proxmox VM) ← ESO reads secrets → k8s Secrets ← pods mount as env vars
```

`ExternalSecret` CRD example:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: discord-webhook
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-backend
    kind: ClusterSecretStore
  target:
    name: discord-webhook-secret
  data:
    - secretKey: url
      remoteRef:
        key: monitoring/discord
        property: webhook_url
```

### AWS career parallel
This pattern maps directly to AWS Secrets Manager + External Secrets Operator on EKS — one of the most commonly asked-about patterns in AWS SysEng interviews. The ESO `ClusterSecretStore` → `ExternalSecret` model is identical whether the backend is OpenBao or AWS Secrets Manager.

### Note on unsealing
OpenBao (like Vault) requires manual unsealing after a reboot. For a homelab this is acceptable — run `bao operator unseal` after any reboot. Auto-unseal via a cloud KMS is possible but out of scope here.

**OpenBao docs:** https://openbao.org/docs/
**External Secrets Operator:** https://external-secrets.io/

---

## Layer 7b: Backup — Velero + etcd Snapshots

The cluster has no recovery path without backup. Two complementary mechanisms cover different failure modes.

### Velero — Kubernetes Resource Backup

Velero backs up all Kubernetes resources (Deployments, Services, ConfigMaps, Secrets, PVCs) as YAML to object storage. If the cluster is rebuilt from scratch, Velero can restore all workloads and their configuration.

- Deployed via ArgoCD HelmRelease to the `velero` namespace (`k8s/backup/`)
- Object storage backend: MinIO on Proxmox (same MinIO used for Terraform state — reuses existing infrastructure)
- Schedule: daily full backup retained for 7 days
- Restore is a single `velero restore create` command

**What Velero covers:** k8s resources, PersistentVolume snapshots (for Prometheus data, Grafana data, Loki logs)
**What Velero does not cover:** etcd state itself — that is a separate mechanism

**Reference:** https://velero.io/docs/latest/

### etcd Snapshots — Cluster State Backup

etcd holds all cluster state. With a 3-node HA control plane, etcd survives individual node failures — but a simultaneous loss of all three or a data corruption event cannot be recovered without a snapshot. kubeadm exposes `etcdctl` on each control plane node.

- A CronJob runs nightly on each control plane node: `etcdctl snapshot save /backup/etcd-$(date +%Y%m%d).db`
- Snapshots are uploaded to MinIO (same bucket as Velero backups, different prefix)
- Restore procedure: `etcdctl snapshot restore` followed by restarting the etcd static pod

**Reference:** https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#backing-up-an-etcd-cluster

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
├── packer/
│   └── ubuntu-2404.pkr.hcl       ← Packer template (builds Proxmox VM template)
│
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── controlplane.tf
│   ├── worker.tf
│   ├── versions.tf
│   └── node_capacities.json      ← per-node max worker counts (placement config)
│
├── ansible/
│   ├── inventory/                ← generated at runtime, gitignored
│   ├── group_vars/
│   ├── roles/
│   │   ├── common/
│   │   ├── containerd/
│   │   ├── kubeadm/
│   │   ├── keepalived/           ← VIP setup across all 3 CP nodes
│   │   ├── controlplane/         ← kubeadm init (pve1 only)
│   │   ├── controlplane-join/    ← kubeadm join --control-plane (pve2, pve3)
│   │   └── worker/
│   ├── runner-setup.yml          ← one-time runner VM configuration
│   └── site.yml
│
├── k8s/                          ← GitOps watched directory (ArgoCD syncs this)
│   ├── namespaces/
│   ├── monitoring/               ← kube-prometheus-stack, Loki, pve-exporter, alert rules, webhook adapter
│   ├── ingress/                  ← ingress-nginx + MetalLB
│   ├── backup/                   ← Velero HelmRelease + etcd snapshot CronJob
│   ├── secrets/                  ← ESO HelmRelease, ClusterSecretStore, ExternalSecret definitions
│   └── apps/
│
├── argocd/
│   ├── root-app.yaml             ← App-of-Apps root (applied once in bootstrap)
│   └── apps/
│       ├── monitoring.yaml
│       ├── ingress.yaml
│       ├── backup.yaml
│       └── secrets.yaml          ← ESO + ExternalSecrets managed by ArgoCD
│
├── renovate.json                 ← Renovate Bot config (auto-PRs for dependency updates)
│
└── .github/
    └── workflows/
        ├── bootstrap.yml         ← one-time cluster creation (workflow_dispatch)
        ├── terraform-plan.yml    ← runs on PRs touching terraform/
        ├── deploy-worker.yml
        ├── remove-worker.yml
        └── resize-worker.yml
```

---

## Layer 10: Build Sequence (Order of Operations)

```
1. One-time Proxmox prep (manual)
   └── Create Proxmox API user + token
   └── Run Packer to build the Ubuntu VM template

2. Terraform state backend (manual)
   └── Create Terraform Cloud account, organisation, workspace

2b. OpenBao + MinIO VMs (manual — must exist before bootstrap)
   └── Clone Proxmox template → OpenBao VM; install + initialise + unseal OpenBao
   └── Load all project secrets into OpenBao kv-v2 engine
   └── Clone Proxmox template → MinIO VM; install MinIO; create velero + tfstate buckets

3. Self-hosted runner (manual + Ansible)
   └── Clone Proxmox template → runner VM
   └── Register runner with GitHub repo
   └── Run ansible/runner-setup.yml from developer machine to install all tools

4. Write all files (no cluster exists yet)
   └── Terraform files (variables, controlplane, worker, outputs, versions)
   └── terraform/node_capacities.json
   └── Ansible roles (common, containerd, kubeadm, keepalived, controlplane, controlplane-join, worker)
   └── ArgoCD manifests (k8s/ingress/, k8s/monitoring/ [incl. Loki + pve-exporter], k8s/backup/ [Velero], k8s/secrets/ [ESO + ExternalSecrets], argocd/)
   └── All GitHub Actions workflows
   └── renovate.json in repo root
   └── Branch protection rules on main (require terraform-plan check + 1 approval)

5. Store GitHub Secrets (manual — only what GitHub Actions itself needs pre-cluster)
   └── TF_API_TOKEN, PROXMOX_API_TOKEN_ID/SECRET, ANSIBLE_SSH_PRIVATE_KEY, GH_DISPATCH_TOKEN, OPENBAO_ADDR, OPENBAO_TOKEN
   └── All other secrets (Discord webhook, MinIO keys) live in OpenBao; ESO syncs them into k8s Secrets inside the cluster

6. Discord setup (manual)
   └── Create webhook URL → store as DISCORD_WEBHOOK_URL secret
   └── (Optional) Create Discord Application + Bot for in-Discord approval buttons

7. GitHub Environments (manual)
   └── Create manual-review environment with required reviewer

8. Run bootstrap workflow (one manual trigger — creates everything)
   └── Terraform creates control plane + first worker VMs
   └── Ansible configures all nodes, inits cluster, joins workers
   └── Calico CNI applied
   └── ArgoCD installed via Helm
   └── ArgoCD App-of-Apps applied → syncs MetalLB, ingress-nginx, monitoring automatically
   └── kubeconfig written to GitHub Secrets automatically
   └── Discord notification: "✅ Cluster bootstrapped"

9. AlertManager bridge (commit to Git → ArgoCD deploys)
   └── PrometheusRule alert definitions committed to k8s/monitoring/
   └── Webhook adapter Deployment committed to k8s/monitoring/
   └── AlertManager routing config committed
   └── ArgoCD syncs all of the above automatically

10. End-to-end test
    └── stress-ng on workers → alerts fire → workflows trigger → Discord notifications → cluster scales
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
| OpenBao (Vault fork) | https://openbao.org/docs/ |
| External Secrets Operator | https://external-secrets.io/latest/ |

---

## Certification / Learning Path Note

Since you're targeting AWS Systems Engineer roles, this stack gives you direct practice for:
- **CKA (Certified Kubernetes Administrator)** — kubeadm, cluster upgrades, etcd backup, networking
- **CKS (Certified Kubernetes Security Specialist)** — network policies (Calico), RBAC, audit logs
- **AWS EKS** — kubeadm internals map directly; ArgoCD is widely deployed on EKS
- **Terraform Associate** — state management, modules, providers, remote backends
- **GitOps patterns** — ArgoCD Application model matches how AWS DevOps teams deploy to EKS

The Proxmox + kubeadm setup intentionally exposes every component you'd normally never see in a managed service, which is exactly the depth AWS SysEng interviews probe.
