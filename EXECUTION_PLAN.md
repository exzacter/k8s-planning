# Execution Plan — K8s Cluster on Proxmox

This document is the step-by-step build guide derived from PLAN.md.
No code is written here — each step is an action with a reference.
Follow phases in order; each phase has hard dependencies on the one before it.

---

## Unavoidably Manual Steps (one-time human actions)

These cannot be automated because they are either initial credentials that must exist before automation can run, or human decisions with no computable answer:

- Creating the Proxmox API user and token (chicken-and-egg — the token is what automation uses)
- Deciding IP ranges (Step 1.5 — your router/LAN layout)
- Creating Terraform Cloud account and organisation (web signup)
- Registering the GitHub Actions runner (GitHub generates the token in the UI)
- Populating GitHub Secrets (you cannot script secret injection)
- Creating the Discord webhook URL and Discord Application (Discord UI)
- Running the bootstrap workflow once (manual trigger — creates the cluster from scratch)

Everything else is automated.

---

## Before You Start — What You Need

- Proxmox VE node(s) running and accessible on your LAN
- GitHub account with the `k8s-planning` repo created
- A developer machine (laptop/desktop) to run the one-time bootstrap operations
- A block of free IPs on your LAN (reserve them in your router's DHCP exclusion list before starting)

---

## Phase 0: Local Tooling (developer machine only)

These tools are only needed on your developer machine for the one-time bootstrap. After the self-hosted runner exists, all subsequent operations run on it.

**Step 0.1 — Install Terraform via tfenv**
> Version manager for Terraform — pins exact version per project.
> Docs: https://github.com/tfutils/tfenv

**Step 0.2 — Install Ansible via pip**
> Use pip, not distro packages — apt/yum versions lag significantly.
> Docs: https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html

**Step 0.3 — Install Ansible Galaxy collections**
> Install `kubernetes.core` and `community.general`.
> Docs: https://docs.ansible.com/ansible/latest/collections_guide/collections_installing.html

**Step 0.4 — Install kubectl, Helm, Packer, jq**
> kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
> Helm: https://helm.sh/docs/intro/install/
> Packer: https://developer.hashicorp.com/packer/install
> jq: https://jqlang.github.io/jq/download/

**Step 0.5 — Generate the Ansible SSH key pair**
> `ssh-keygen` using ed25519. The public key goes into every VM via cloud-init.
> The private key gets stored as a GitHub Actions secret and placed on the runner.

---

## Phase 1: Proxmox Preparation

**Step 1.1 — Create a dedicated Proxmox user for Terraform**
> Do not use root. Create `terraform@pve` with minimum required roles:
> VM.Allocate, VM.Clone, VM.Config.*, Datastore.AllocateSpace, SDN.Use.
> Docs: https://pve.proxmox.com/wiki/User_Management

**Step 1.2 — Create a Proxmox API token for that user**
> Proxmox UI → Datacenter → Permissions → API Tokens → Add.
> Store the Token ID and Secret immediately — the secret is only shown once.
> Docs: https://pve.proxmox.com/wiki/Proxmox_VE_API#API_Tokens

**Step 1.3 — Write a Packer template for the base VM image**
> Packer automates the entire VM template creation process — no manual Proxmox UI clicks.
> The Packer `proxmox-iso` or `proxmox-clone` builder:
> - Downloads the Ubuntu 24.04 cloud image directly on Proxmox
> - Creates a VM, attaches the image, boots it
> - Runs a provisioner shell script: installs `qemu-guest-agent`, enables it, disables swap, applies updates
> - Converts the VM to a Proxmox template automatically
> Store the Packer template in `packer/ubuntu-2404.pkr.hcl` in the repo.
> Packer proxmox builder docs: https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox
> Packer proxmox-clone builder: https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/clone

**Step 1.4 — Run Packer to build the template (one-time, from developer machine)**
> `packer build packer/ubuntu-2404.pkr.hcl` — Packer authenticates to Proxmox API and builds the template.
> After this, the template exists on Proxmox and Terraform can clone it for every VM.
> If the template ever needs to be rebuilt (e.g. OS updates), re-run Packer — it replaces the old template.

**Step 1.5 — Plan and reserve IP ranges**
> Decide on these ranges and set them as DHCP exclusions in your router before writing any Terraform.
> Every IP listed here must be excluded from DHCP so no other device on the LAN can claim them.
>
> | Purpose | Count | Example range |
> |---|---|---|
> | Control plane VIP (keepalived) | 1 | 192.168.1.9 |
> | Control plane VM — pve1 | 1 | 192.168.1.10 |
> | Control plane VM — pve2 | 1 | 192.168.1.11 |
> | Control plane VM — pve3 | 1 | 192.168.1.12 |
> | Workers — pve1 (max 3) | 3 | 192.168.1.100–102 |
> | Workers — pve2 (max 6) | 6 | 192.168.1.110–115 |
> | Workers — pve3 (max 4) | 4 | 192.168.1.120–123 |
> | Workers — pve4 (max 2) | 2 | 192.168.1.130–131 |
> | Self-hosted runner VM | 1 | 192.168.1.50 |
> | MetalLB pool (LoadBalancer Services) | 20 | 192.168.1.200–219 |
>
> The per-node worker ranges will be codified in `terraform/node_capacities.json` in Phase 5a.
> CP IPs and VIP will be hardcoded as defaults in `terraform/variables.tf` in Phase 5b.
> Adjust ranges to your actual LAN subnet — the above are illustrative only.
> pve4 will only run worker VMs, never control plane VMs.

**Step 1.6 — Verify Proxmox API access from your developer machine**
> Use curl to call `GET /api2/json/nodes` with the API token from Step 1.2.
> A successful JSON response confirms auth before any Terraform is written.
> API reference: https://pve.proxmox.com/pve-docs/api-viewer/

---

## Phase 2: Terraform Cloud State Backend

**Step 2.1 — Create a Terraform Cloud account and organisation**
> Sign up at https://app.terraform.io — free tier is sufficient.

**Step 2.2 — Create a workspace in CLI-driven mode**
> CLI-driven means Terraform runs in GitHub Actions, not inside HCP.
> Name it `k8s-proxmox`.
> Docs: https://developer.hashicorp.com/terraform/cloud-docs/workspaces/creating

**Step 2.3 — Generate a Terraform Cloud API token**
> Account Settings → Tokens → Create API token.
> Docs: https://developer.hashicorp.com/terraform/cloud-docs/users-teams-organizations/api-tokens

**Step 2.4 — Authenticate your local Terraform CLI**
> `terraform login` — stores the token locally for the bootstrap phase.
> Docs: https://developer.hashicorp.com/terraform/cli/commands/login

---

## Phase 3: Self-Hosted GitHub Actions Runner

> GitHub-hosted runners cannot reach your home LAN. Every workflow must run on this self-hosted runner.

**Step 3.1 — Create the runner VM on Proxmox**
> Use the Proxmox UI to clone the template from Phase 1.4 — this is the only VM created outside Terraform.
> The runner is not a k8s node. It needs network access to: Proxmox API, all VM IPs, and the internet.
> Specs: 2 CPU, 4 GB RAM, 20 GB disk is sufficient.

**Step 3.2 — Register the runner with your GitHub repo**
> GitHub repo → Settings → Actions → Runners → New self-hosted runner.
> Follow the Linux steps to download, configure, and install the runner as a systemd service.
> Tag it with a label (e.g. `proxmox-lan`) — all workflows use `runs-on: [self-hosted, proxmox-lan]`.
> Docs: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners

**Step 3.3 — Configure the runner VM with Ansible (from your developer machine)**
> Rather than manually installing tools on the runner, write an Ansible playbook at `ansible/runner-setup.yml`.
> Run it once from your developer machine targeting the runner VM's IP.
> The playbook installs: Terraform (pinned version via tfenv), Ansible, kubectl, Helm, git, curl, jq, Python3.
> After this, the runner has everything it needs to execute any workflow.

**Step 3.4 — Place the Ansible SSH private key on the runner**
> The runner needs the private key from Step 0.5 to SSH into k8s VMs during Ansible runs.
> Copy it to `~/.ssh/ansible_key` on the runner VM and set permissions to 600.
> This same key is stored as a GitHub Secret — the bootstrap workflow writes it to this path at runtime.

**Step 3.5 — Confirm runner is Idle in GitHub**
> GitHub repo → Settings → Actions → Runners — runner should show as "Idle".

---

## Phase 4: Repository Structure

**Step 4.1 — Create the directory skeleton**
> Create these directories with a `.gitkeep` so they appear in Git:
> `packer/`, `terraform/`, `ansible/inventory/`, `ansible/roles/`, `ansible/group_vars/`,
> `k8s/namespaces/`, `k8s/monitoring/`, `k8s/ingress/`, `k8s/backup/`, `k8s/apps/`,
> `argocd/apps/`, `.github/workflows/`

**Step 4.2 — Create `.gitignore`**
> Exclude: `*.tfstate`, `*.tfstate.backup`, `.terraform/`, `*.tfvars`, `ansible/inventory/hosts.ini`, `kubeconfig`, `packer/manifest.json`

**Step 4.3 — Create `terraform/versions.tf`**
> Declare pinned Terraform version, `bpg/proxmox` provider version, and the Terraform Cloud backend block.
> Provider version reference: https://registry.terraform.io/providers/bpg/proxmox/latest

**Step 4.4 — Create `renovate.json` in the repo root**
> Renovate Bot automatically opens PRs when new versions of Helm charts, Terraform providers, container images, or GitHub Actions are released.
> The config file tells Renovate what to scan and how to group updates.
> Minimal starting config:
> ```json
> {
>   "$schema": "https://docs.renovatebot.com/renovate-schema.json",
>   "extends": ["config:base"],
>   "packageRules": [
>     { "matchPackagePatterns": ["*"], "groupName": "all dependencies", "groupSlug": "all" }
>   ]
> }
> ```
> After committing this file, install the Renovate GitHub App at https://github.com/apps/renovate and grant it access to this repo.
> Renovate will open an onboarding PR showing what it detected — review and merge it.
> Reference: https://docs.renovatebot.com/configuration-options/

**Step 4.5 — Configure branch protection rules on `main`**
> In GitHub: Settings → Branches → Add branch protection rule for `main`.
> Enable:
> - Require a pull request before merging (1 approval minimum)
> - Require status checks to pass before merging — add `terraform-plan` as a required check (write the workflow in Phase 5.6 first, then come back and add the check name)
> - Require branches to be up to date before merging
> - Do not allow force pushes
> This ensures no infrastructure change can be merged without a passing Terraform plan and at least one review.
> Reference: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches

---

## Phase 5: Terraform File Definitions

> Write all Terraform files in this phase. Nothing is applied yet — that happens in the bootstrap workflow.

### 5a: Node Capacity Config

**Step 5a.1 — Inventory your Proxmox nodes and their practical worker limits**
> For each Proxmox node, determine how many k8s worker VMs it can host given available RAM, CPU, and storage.
> Example: a 64 GB node with other workloads might support 3 workers at 8 GB each.

**Step 5a.2 — Create `terraform/node_capacities.json`**
> Committed to Git. Maps each Proxmox node to its maximum worker count and its dedicated IP range for worker VMs.
> Each node gets a non-overlapping range sized exactly to its max worker count.
> Example:
> ```json
> {
>   "pve1": { "max_workers": 3, "worker_ip_start": "192.168.1.100", "worker_ip_end": "192.168.1.102" },
>   "pve2": { "max_workers": 6, "worker_ip_start": "192.168.1.110", "worker_ip_end": "192.168.1.115" },
>   "pve3": { "max_workers": 4, "worker_ip_start": "192.168.1.120", "worker_ip_end": "192.168.1.123" },
>   "pve4": { "max_workers": 2, "worker_ip_start": "192.168.1.130", "worker_ip_end": "192.168.1.131" }
> }
> ```
> All IPs in these ranges must also be in the DHCP exclusion list you configured in Step 1.5 — otherwise your router may hand them to other devices.
> Changing a node's capacity or IP range is a Git commit — fully auditable.
> The deploy-worker workflow reads this file to determine placement AND to select the next available IP for the new VM.

**Step 5a.3 — Document the worker naming convention**
> Pattern: `worker-{proxmox-node}-{zero-padded-sequence}` (e.g. `worker-pve2-01`, `worker-pve1-03`)
> The node name embedded in the VM name is what allows the placement algorithm to count workers per node
> by filtering the Proxmox API response — no separate tracking database needed.

### 5b: Terraform Resources

**Step 5.1 — Write `terraform/variables.tf`**
> Variables needed: Proxmox API URL, token ID (sensitive), token secret (sensitive), template name, SSH public key, network bridge name, LAN gateway, LAN DNS server.
>
> Static IPs for control plane — defined as defaults in variables.tf, never change after first apply:
> - `controlplane_ips` — map of CP node name → static IP (e.g. `{ "pve1": "192.168.1.10", "pve2": "192.168.1.11", "pve3": "192.168.1.12" }`)
> - `controlplane_vip` — the keepalived virtual IP (e.g. `"192.168.1.9"`) — this is the address kubeadm and all workers use to reach the API server
>
> The workers variable is a **map of objects** — key = worker name, value = `{node, memory, cores, ip}`.
> The `ip` field is populated by the deploy-worker workflow before calling Terraform — Terraform never picks IPs itself.
> Never use a simple `worker_count` integer — the map is the interface.

**Step 5.2 — Write `terraform/main.tf`**
> Configure `bpg/proxmox` provider with variables.
> Reference: https://registry.terraform.io/providers/bpg/proxmox/latest/docs#argument-reference

**Step 5.3 — Write `terraform/controlplane.tf`**
> Three `proxmox_virtual_environment_vm` resources using `for_each` over a map of `{controlplane-pve1, controlplane-pve2, controlplane-pve3}`.
> Each VM targets its respective Proxmox node (pve1, pve2, pve3). pve4 receives no control plane VMs.
> Cloud-init per VM: hostname, SSH public key, static IP (from the three reserved CP IPs).
> Also define a variable for the keepalived VIP address — this is passed into Ansible and used as the kubeadm `--control-plane-endpoint`.
> Reference: https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm
> kubeadm HA reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/

**Step 5.4 — Write `terraform/worker.tf`**
> `proxmox_virtual_environment_vm` resource using `for_each` over the workers map.
> `each.key` = VM name, `each.value.node` = target Proxmox node, `each.value.memory` = RAM, `each.value.ip` = static IP.
> The cloud-init `initialization` block uses `each.value.ip` to set the static IP, gateway, and DNS on each VM at boot — no manual network config, no DHCP.
> Using a map (not `count`) means modifying one worker never touches others.
> Reference: https://developer.hashicorp.com/terraform/language/meta-arguments/for_each
> bpg/proxmox cloud-init reference: https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm#initialization

**Step 5.5 — Write `terraform/outputs.tf`**
> Output: map of CP node names → IPs (all three), VIP address, map of worker names → IPs, map of worker names → Proxmox nodes.
> Worker IPs in the output are the same values that were passed in via the workers map — Terraform is not discovering them, it is echoing back what the workflow gave it.
> The CP IPs and VIP feed into Ansible inventory generation. The worker map feeds the remove-worker workflow so it knows which Proxmox node to destroy a given VM on.
> The deploy-worker and remove-worker workflows both use `terraform show -json` to read current state rather than relying on output files, so state is always authoritative.

**Step 5.6 — Create a CI workflow for `terraform plan` on pull requests**
> File: `.github/workflows/terraform-plan.yml`
> Trigger: pull request that modifies any file under `terraform/`
> Steps: `terraform init` → `terraform plan` → post the plan output as a PR comment
> This is for visibility and review — it does not block the merge.
> The comment lets you see exactly what Terraform will change before it runs.
> Reference: https://developer.hashicorp.com/terraform/tutorials/automation/github-actions

---

## Phase 6: Ansible Role Definitions

> Write all Ansible roles in this phase. Nothing is run yet — the bootstrap workflow executes them.

**Step 6.1 — Write `ansible/group_vars/all.yml`**
> Shared variables: Kubernetes version (e.g. `1.30`), pod CIDR (`192.168.0.0/16`), SSH user (`ubuntu`), SSH key path.

**Step 6.2 — Write the `common` role**
> Targets all nodes. Disables swap, loads `overlay` + `br_netfilter` kernel modules, sets required sysctl params, installs apt dependencies.
> Reference: https://kubernetes.io/docs/setup/production-environment/container-runtimes/

**Step 6.3 — Write the `containerd` role**
> Installs containerd from Docker's apt repo. Generates default config, sets `SystemdCgroup = true`. Restarts service.
> Reference: https://docs.docker.com/engine/install/ubuntu/

**Step 6.4 — Write the `kubeadm` role**
> Adds Kubernetes apt repo, installs `kubeadm`, `kubelet`, `kubectl` at pinned version, holds versions with `apt-mark hold`.
> Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/

**Step 6.5 — Write the `keepalived` role**
> Installs and configures keepalived on all three CP VMs to provide the VIP.
> The primary CP node (pve1) holds the VIP by default; pve2 and pve3 take over if pve1 fails.
> The VIP address comes from the Ansible variable set in group_vars/controlplane.yml.
> Reference: https://keepalived.readthedocs.io/en/latest/configuration_synopsis.html
> keepalived on Ubuntu: https://ubuntu.com/server/docs/network-configuration (keepalived section)

**Step 6.6 — Write the `controlplane` role (primary node only — pve1)**
> Runs `kubeadm init --control-plane-endpoint <VIP>:6443 --upload-certs --pod-network-cidr=192.168.0.0/16`.
> `--upload-certs` uploads the cluster CA to etcd so secondary CP nodes can retrieve them during join (avoids manual cert copying).
> Copies `admin.conf` to the ubuntu home directory.
> Saves the worker join command and the certificate key to files (Ansible will fetch these to use in subsequent steps).
> Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/

**Step 6.7 — Write the `controlplane-join` role (secondary nodes — pve2, pve3)**
> Fetches the certificate key and join command from the primary CP node (via Ansible fetch).
> Runs `kubeadm join <VIP>:6443 --control-plane --certificate-key <key>` on pve2 and pve3 sequentially.
> Verifies each node appears as a control plane member before joining the next.
> Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/#steps-for-the-rest-of-the-control-plane-nodes

**Step 6.8 — Write the `worker` role**
> Reads the worker join command (fetched from primary CP), runs `kubeadm join <VIP>:6443`.
> Workers always join via the VIP — if any CP node is down, the VIP routes them to a healthy API server.
> Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#join-nodes

---

## Phase 7: ArgoCD-Managed Add-ons (write manifests, don't apply yet)

> MetalLB, ingress-nginx, and monitoring are all managed by ArgoCD via Git from the start.
> Write the manifests now — they get applied automatically once ArgoCD is bootstrapped in Phase 9.

**Step 7.1 — Write MetalLB manifests in `k8s/ingress/`**
> An ArgoCD `Application` pointing to the MetalLB Helm chart.
> A `ConfigMap` with the `IPAddressPool` and `L2Advertisement` custom resources using the IPs from Step 1.5.
> Reference: https://metallb.universe.tf/installation/

**Step 7.2 — Write ingress-nginx manifest in `k8s/ingress/`**
> An ArgoCD `Application` pointing to the ingress-nginx Helm chart.
> Reference: https://kubernetes.github.io/ingress-nginx/deploy/

**Step 7.3 — Write kube-prometheus-stack manifest in `k8s/monitoring/`**
> An ArgoCD `Application` pointing to the kube-prometheus-stack Helm chart.
> Values: enable persistent storage, Grafana admin password via Secret reference, node-exporter DaemonSet enabled.
> Reference: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

**Step 7.4 — Write Grafana dashboard provisioning config**
> Grafana can auto-import dashboards via a `ConfigMap` containing dashboard JSON and a provisioning config.
> Add Node Exporter Full (ID 1860) and Kubernetes Overview (ID 7249) as provisioned dashboards.
> This eliminates the manual "import dashboard" UI step.
> Reference: https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards

**Step 7.5 — Write the ArgoCD App-of-Apps root application**
> A single `Application` manifest in `argocd/` that points to `argocd/apps/`.
> ArgoCD discovers and syncs everything inside `argocd/apps/` automatically.
> Reference: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/

**Step 7.6 — Write Loki + Promtail manifests in `k8s/monitoring/`**
> An ArgoCD `Application` pointing to the `grafana/loki-stack` Helm chart (bundles Loki + Promtail together).
> Promtail deploys as a DaemonSet and automatically discovers and ships all container and system logs from every node to Loki.
> In Grafana (already deployed via kube-prometheus-stack), add Loki as a datasource — this is done via a `ConfigMap` in the same way Grafana dashboards are provisioned, so no manual UI step.
> With Loki added, Grafana's Explore view lets you search logs across all nodes in the same UI as your metrics.
> Reference: https://grafana.com/docs/loki/latest/setup/install/helm/
> Loki datasource provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources

**Step 7.7 — Write Velero manifest in `k8s/backup/`**
> An ArgoCD `Application` pointing to the Velero Helm chart deployed to the `velero` namespace.
> Helm values: set the object storage backend to MinIO (same MinIO used for Terraform state), configure credentials, enable the default backup storage location.
> A `Schedule` CRD resource in the same directory triggers a daily full backup at 02:00 with 7-day retention.
> A separate `CronJob` manifest on each control plane node runs `etcdctl snapshot save` nightly and uploads the snapshot to MinIO under an `etcd/` prefix.
> No manual backup triggers — everything is GitOps-managed and runs automatically once ArgoCD syncs it.
> Reference: https://velero.io/docs/latest/basic-install/
> Velero Helm chart: https://vmware-tanzu.github.io/helm-charts/

**Step 7.8 — Write prometheus-pve-exporter manifest in `k8s/monitoring/`**
> A `Deployment` running the `prometheus-pve-exporter` container, pointed at the Proxmox API URL with the API token stored in a k8s Secret.
> A `Service` and `ServiceMonitor` CRD so Prometheus (via kube-prometheus-stack) automatically discovers and scrapes the exporter.
> This adds Proxmox-layer metrics to Grafana: per-Proxmox-node CPU/RAM, VM power states, storage pool utilisation.
> Cross-referencing these with the placement algorithm in deploy-worker lets you see if a Proxmox host is saturated before committing to placing a VM there.
> Reference: https://github.com/prometheus-pve/prometheus-pve-exporter

---

## Phase 8: Discord Integration

> Discord notifications fire on every cluster event. Approval gates pause automated workflows for human review when needed.

### 8a: One-Way Notifications (Discord Webhook)

**Step 8.1 — Create a Discord server and channel for cluster notifications**
> Dedicated channel (e.g. `#k8s-events`) keeps cluster events separate from conversation.

**Step 8.2 — Create a Discord webhook for that channel**
> Channel Settings → Integrations → Webhooks → New Webhook → Copy URL.
> Store the URL as a GitHub Secret: `DISCORD_WEBHOOK_URL`.
> Discord webhook reference: https://discord.com/developers/docs/resources/webhook#execute-webhook

**Step 8.3 — Define the notification events**
> Every GitHub Actions workflow sends a Discord message at these points:

| Trigger | Message | Colour |
|---|---|---|
| Workflow starts | "⏳ Deploying/Removing/Resizing worker {name} on {node}" | Yellow |
| Workflow succeeds | "✅ {action} complete — {name} is Ready" | Green |
| Workflow fails | "❌ {action} failed — link to run: {url}" | Red |
| All nodes at capacity | "🚨 @here Cluster at full capacity — manual action needed" | Red |
| Scale-in blocked (last worker) | "⚠️ Scale-in blocked — only 1 worker remaining" | Yellow |
| Resize cap hit → horizontal scale | "ℹ️ {name} at 16 GB cap — triggering scale-out" | Blue |

> Each workflow adds a Discord notification step using a `curl` POST to `DISCORD_WEBHOOK_URL`.
> Use Discord's embed format for colour-coded messages.
> Embed format reference: https://discord.com/developers/docs/resources/message#embed-object

### 8b: Two-Way Approval Gates

> For scenarios requiring human decision before automation proceeds, you have two options.
> They are not mutually exclusive — use Environments as the base and add the Discord Bot later.

**Option A — GitHub Environments + Required Reviewers (recommended starting point)**

> GitHub Actions environments have a built-in approval mechanism. When a workflow step uses a protected environment, it pauses and sends a notification until a named reviewer approves or rejects on GitHub.
> The Discord notification for the blocked event includes a direct link to the GitHub approval page.
> Zero extra infrastructure required.

**Step 8b-A.1 — Create a `manual-review` environment in GitHub**
> GitHub repo → Settings → Environments → New environment → name it `manual-review`.
> Add yourself (and anyone else) as a required reviewer.
> Docs: https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment

**Step 8b-A.2 — Identify which workflow paths hit the gate**
> The gate step (using the `manual-review` environment) only fires when automation cannot proceed alone:
> - `deploy-worker` → all Proxmox nodes are at capacity
> - `remove-worker` → removing this node would leave 0 workers in the cluster
> - `deploy-worker` or `remove-worker` → Terraform plan includes an unexpected destroy of a non-target VM
> All other paths run fully automatically with no gate.

**Step 8b-A.3 — Structure: notification → gate → proceed**
> Workflow: detect the blocked condition → send Discord notification with the GitHub approval URL → enter the `manual-review` environment step → wait for approval → continue or cancel.
> The approval URL is accessible from the Discord message — no need to navigate GitHub separately.

---

**Option B — Discord Bot with Button Interactions (in-Discord yes/no)**

> This gives a native Discord experience: the blocked event sends a message with Yes/No buttons directly in Discord. Clicking a button triggers the workflow to continue or cancel — no GitHub UI needed.
> More complex to build but significantly better UX for an always-open Discord server.

**Step 8b-B.1 — Create a Discord Application and Bot**
> Discord Developer Portal → New Application → Add a Bot.
> Note the bot token — this is what the interactions server authenticates with.
> Portal: https://discord.com/developers/applications

**Step 8b-B.2 — Set up a Cloudflare Tunnel to expose the interactions endpoint**
> Discord requires the bot's interactions endpoint to be publicly reachable over HTTPS with a valid certificate.
> Cloudflare Tunnel creates a public HTTPS URL tunnelled to a service running inside your cluster — no port forwarding or public IP needed.
> Install `cloudflared` as a k8s Deployment (managed by ArgoCD). It connects outbound to Cloudflare and maps a subdomain to your bot service's ClusterIP.
> Cloudflare Tunnel docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/

**Step 8b-B.3 — Write the Discord interactions server**
> A small HTTP server (Python FastAPI or Go) deployed as a k8s Deployment in a `discord-bot` namespace.
> It handles two things:
> 1. Receives Discord interaction payloads (button clicks) at `/interactions`
> 2. Verifies the Discord signature on every request (required by Discord)
> 3. On "Yes" click: calls the GitHub API to fire a `repository_dispatch` event with type `approval-granted` + the pending workflow context
> 4. On "No" click: calls GitHub API with type `approval-denied`
> Discord interaction model: https://discord.com/developers/docs/interactions/overview
> Signature verification: https://discord.com/developers/docs/interactions/overview#setting-up-an-endpoint-verifying-security-keys

**Step 8b-B.4 — Update deploy-worker and remove-worker workflows for Discord approval path**
> When a blocked condition is detected:
> - POST a Discord message with two buttons ("Proceed" / "Cancel") via the bot token
> - Include the pending action details in the message (node, reason for block)
> - Workflow then polls for an `approval-granted` or `approval-denied` repository_dispatch event (or uses a timeout)
> - On approval: continue the workflow
> - On denial or timeout: exit cleanly with a summary notification

---

## Phase 9: Bootstrap Workflow (one-time cluster creation)

> This is the single manually-triggered workflow that creates everything from scratch.
> After this workflow succeeds, the cluster is running and all subsequent operations are automated.

**Step 9.1 — Write the bootstrap workflow**
> File: `.github/workflows/bootstrap.yml`
> Trigger: `workflow_dispatch` (manually triggered once — this is the one acceptable manual trigger)
> Runs on: self-hosted runner (Phase 3)
> Steps in order:
>
> 1. Checkout repo
> 2. Write Ansible SSH private key from secret to `~/.ssh/ansible_key`
> 3. `terraform init` + `terraform apply` — creates control plane VM + first worker VM on the best-capacity node
> 4. Generate Ansible inventory from `terraform output -json` using `jq`
> 5. Run `ansible-playbook site.yml` (all roles) — configures OS, installs containerd/kubeadm, inits control plane, joins worker
> 6. Apply Calico CNI manifests via kubectl
> 7. Wait for all nodes `Ready`
> 8. Install ArgoCD via `helm install` — this is the only manual Helm install; ArgoCD manages everything after this
> 9. Wait for ArgoCD pods `Ready`
> 10. Connect ArgoCD to the GitHub repo using `argocd repo add` (via argocd CLI or kubectl apply of a Repository secret)
> 11. Apply the root App-of-Apps Application — ArgoCD picks up `argocd/apps/` and begins syncing MetalLB, ingress-nginx, monitoring
> 12. Wait for all ArgoCD applications to reach `Synced/Healthy`
> 13. Retrieve kubeconfig from control plane, base64-encode it, write it to GitHub Secrets via the GitHub API
> 14. Send Discord notification: "✅ Cluster bootstrapped — {worker_count} workers ready, ArgoCD synced"
>
> ArgoCD CLI docs: https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd/
> ArgoCD repo secret: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories

---

## Phase 10: AlertManager Rules and Webhook Adapter

> These are all written as k8s manifests and deployed via ArgoCD from `k8s/monitoring/`.

**Step 10.1 — Write the three PrometheusRule alert definitions**
> `k8s/monitoring/alert-rules.yaml` — a `PrometheusRule` CRD with:
> - `NodeMemoryPressure`: single worker RAM > 75% for 5 minutes
> - `NodeMemoryLow`: single worker RAM < 30% for 15 minutes
> - `ClusterHighLoad`: ALL workers simultaneously > 75% RAM
> Reference: https://prometheus-operator.dev/docs/user-guides/alerting/

**Step 10.2 — Write and deploy the webhook adapter**
> `k8s/monitoring/webhook-adapter.yaml` — a `Deployment` + `Service` in the `monitoring` namespace.
> The adapter translates AlertManager's webhook payload into GitHub's `repository_dispatch` format, injecting the node label from the alert into `client_payload.node`.
> Store the GitHub PAT as a k8s Secret in the same namespace — the adapter reads it from there.
> Reference: https://github.com/prometheus-community/alertmanager-webhook-adapter

**Step 10.3 — Write AlertManager routing config**
> Update the kube-prometheus-stack Helm values (or write an `AlertmanagerConfig` CRD) to route:
> - `NodeMemoryPressure` → webhook adapter → `memory-pressure` dispatch
> - `NodeMemoryLow` → webhook adapter → `scale-in` dispatch
> - `ClusterHighLoad` → webhook adapter → `scale-out` dispatch
> AlertmanagerConfig CRD: https://prometheus-operator.dev/docs/user-guides/alerting/#using-alertmanagerconfig

**Step 10.4 — Commit all monitoring manifests**
> Committing to Git triggers ArgoCD to sync and apply them automatically — no manual kubectl needed.

---

## Phase 11: GitHub Actions Secrets

**Step 11.1 — Store all secrets in GitHub Actions**
> GitHub repo → Settings → Secrets and variables → Actions.
> Required secrets:
> - `TF_API_TOKEN` — Terraform Cloud API token
> - `PROXMOX_API_TOKEN_ID` — Proxmox API token ID
> - `PROXMOX_API_TOKEN_SECRET` — Proxmox API token secret
> - `ANSIBLE_SSH_PRIVATE_KEY` — Ansible SSH private key
> - `DISCORD_WEBHOOK_URL` — Discord channel webhook URL
> - `GH_DISPATCH_TOKEN` — GitHub PAT with `workflow` scope (for webhook adapter + Discord bot)
> Note: `KUBECONFIG_B64` is written automatically by the bootstrap workflow (Step 9.1 step 13).

**Step 11.2 — Set Terraform Cloud workspace environment variables**
> Proxmox credentials set as sensitive environment variables in Terraform Cloud workspace.
> This keeps them out of workflow YAML files entirely.
> Docs: https://developer.hashicorp.com/terraform/cloud-docs/workspaces/variables

---

## Phase 12: The Three Scaling Workflows

> All three workflows run on the self-hosted runner. All three send Discord notifications. None have manual triggers.

**Step 12.1 — Write `deploy-worker` workflow**
> File: `.github/workflows/deploy-worker.yml`
> Trigger: `repository_dispatch` type `scale-out`
> Steps:
> 1. Send Discord: "⏳ Scale-out triggered — selecting placement node"
> 2. Read `terraform/node_capacities.json`
> 3. Query Proxmox API per node, count workers by name pattern
> 4. Calculate remaining capacity, select best node; if all full → send Discord "🚨 @here at capacity" → enter `manual-review` environment gate → on approval update `node_capacities.json` or cancel
> 5. Derive new worker name (`worker-{node}-{next_seq}`)
> 6. `terraform init` + `terraform apply` with new worker added to map
> 7. Generate inventory for new VM IP from `terraform output`
> 8. Run Ansible `site.yml` targeting new VM only
> 9. Poll `kubectl get nodes` until new node is `Ready` (5-minute timeout; on timeout → send Discord failure + fail workflow)
> 10. Send Discord: "✅ Worker {name} joined cluster on {node}"

**Step 12.2 — Write `remove-worker` workflow**
> File: `.github/workflows/remove-worker.yml`
> Trigger: `repository_dispatch` type `scale-in`
> Steps:
> 1. Send Discord: "⏳ Scale-in triggered for {node}"
> 2. Re-query Prometheus API — confirm still < 30% RAM; if recovered → send Discord "ℹ️ Scale-in cancelled — node recovered" → exit cleanly
> 3. Count current workers — if only 1 remains → send Discord "⚠️ Scale-in blocked — last worker" → enter `manual-review` gate
> 4. `kubectl drain {node} --ignore-daemonsets --delete-emptydir-data`
> 5. `kubectl delete node {node}`
> 6. Remove worker entry from workers map, `terraform apply` → VM destroyed on Proxmox
> 7. Verify node absent from `kubectl get nodes`
> 8. Send Discord: "✅ Worker {name} removed — cluster at {remaining} workers"
> Prometheus HTTP API: https://prometheus.io/docs/prometheus/latest/querying/api/

**Step 12.3 — Write `resize-worker` workflow**
> File: `.github/workflows/resize-worker.yml`
> Trigger: `repository_dispatch` type `memory-pressure`
> Steps:
> 1. Send Discord: "⏳ Memory pressure on {node} — checking current allocation"
> 2. Read current RAM for target VM from `terraform show -json`
> 3. **Decision gate:**
>    - If current RAM < 16 GB: send Discord "⏳ Vertically scaling {name}: {old}GB → {new}GB"; cordon → drain → terraform apply (+4 GB) → wait for Ready → uncordon → send Discord "✅ Resize complete"
>    - If current RAM >= 16 GB: send Discord "ℹ️ {name} at cap (16 GB) — triggering horizontal scale-out"; fire `scale-out` repository_dispatch → exit
> `terraform show` docs: https://developer.hashicorp.com/terraform/cli/commands/show

---

## Phase 13: End-to-End Verification

> All verification is done by observing automated behaviour — no manual kubectl commands for the scaling paths.

**Step 13.1 — Test scale-out**
> Run `stress-ng --vm 1 --vm-bytes 90%` on ALL workers simultaneously.
> Observe in order (no manual intervention needed):
> - AlertManager fires `ClusterHighLoad` after 5 minutes
> - Discord notification appears in `#k8s-events`
> - `deploy-worker` workflow appears in GitHub Actions tab
> - New VM visible in Proxmox UI on the highest-capacity node
> - New node appears as `Ready` in `kubectl get nodes`
> - Discord success notification appears

**Step 13.2 — Test resize**
> Run `stress-ng --vm 1 --vm-bytes 80%` on ONE worker.
> Observe: `NodeMemoryPressure` alert → `resize-worker` workflow → cordon/drain/resize/rejoin → Discord notifications at each stage.
> Verify the new RAM value in `terraform show`.

**Step 13.3 — Test the 16 GB cap → horizontal trigger**
> Manually update the workers map in Terraform to set one worker to 16 GB, apply.
> Stress that worker. Confirm `resize-worker` detects the cap and triggers `deploy-worker` instead.
> Discord should show both the "cap hit" notification and the subsequent scale-out notification.

**Step 13.4 — Test scale-in**
> Let workers idle. After 15 minutes, `NodeMemoryLow` fires.
> Observe: `remove-worker` workflow → drain → destroy → Discord success notification.
> Confirm `terraform show` no longer lists the removed VM.

**Step 13.5 — Test approval gate (capacity full)**
> Temporarily lower `node_capacities.json` to make all nodes appear full.
> Stress the cluster to trigger `ClusterHighLoad`.
> Confirm: Discord shows "🚨 @here at capacity" message with GitHub approval link → workflow pauses at `manual-review` gate → approve on GitHub (or via Discord bot if built) → workflow either proceeds or exits cleanly.
> Reset `node_capacities.json` after testing.

---

## Key Resources Reference

| Topic | Resource |
|---|---|
| Proxmox API tokens | https://pve.proxmox.com/wiki/Proxmox_VE_API#API_Tokens |
| Proxmox cloud-init | https://pve.proxmox.com/wiki/Cloud-Init_Support |
| Proxmox list VMs per node | https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu |
| Packer proxmox builder | https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox |
| bpg/proxmox provider | https://registry.terraform.io/providers/bpg/proxmox/latest/docs |
| bpg/proxmox VM data source | https://registry.terraform.io/providers/bpg/proxmox/latest/docs/data-sources/virtual_environment_vms |
| Terraform for_each | https://developer.hashicorp.com/terraform/language/meta-arguments/for_each |
| Terraform Cloud workspaces | https://developer.hashicorp.com/terraform/cloud-docs/workspaces/creating |
| Terraform GitHub Actions | https://developer.hashicorp.com/terraform/tutorials/automation/github-actions |
| GitHub self-hosted runners | https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners |
| GitHub Environments (approval gates) | https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment |
| GitHub repository_dispatch | https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event |
| kubeadm install | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/ |
| kubeadm cluster creation | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/ |
| containerd install | https://docs.docker.com/engine/install/ubuntu/ |
| Calico CNI | https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises |
| MetalLB L2 | https://metallb.universe.tf/configuration/#layer-2-configuration |
| ingress-nginx | https://kubernetes.github.io/ingress-nginx/deploy/ |
| ArgoCD install | https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/ |
| ArgoCD App-of-Apps | https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/ |
| ArgoCD declarative setup | https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/ |
| kube-prometheus-stack | https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack |
| Grafana dashboard provisioning | https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards |
| PrometheusRule CRD | https://prometheus-operator.dev/docs/user-guides/alerting/ |
| AlertManager config | https://prometheus.io/docs/alerting/latest/configuration/ |
| alertmanager-webhook-adapter | https://github.com/prometheus-community/alertmanager-webhook-adapter |
| Prometheus HTTP API | https://prometheus.io/docs/prometheus/latest/querying/api/ |
| Discord webhook format | https://discord.com/developers/docs/resources/webhook#execute-webhook |
| Discord embed format | https://discord.com/developers/docs/resources/message#embed-object |
| Discord Developer Portal | https://discord.com/developers/applications |
| Discord interactions overview | https://discord.com/developers/docs/interactions/overview |
| Discord signature verification | https://discord.com/developers/docs/interactions/overview#setting-up-an-endpoint-verifying-security-keys |
| Cloudflare Tunnel | https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/ |
| Loki Helm chart | https://grafana.com/docs/loki/latest/setup/install/helm/ |
| Loki datasource provisioning | https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources |
| Velero install | https://velero.io/docs/latest/basic-install/ |
| Velero Helm chart | https://vmware-tanzu.github.io/helm-charts/ |
| prometheus-pve-exporter | https://github.com/prometheus-pve/prometheus-pve-exporter |
| Renovate Bot config | https://docs.renovatebot.com/configuration-options/ |
| Renovate GitHub App | https://github.com/apps/renovate |
| Branch protection rules | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches |
