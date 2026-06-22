# Execution Plan — K8s Cluster on Proxmox

This document is the step-by-step build guide derived from PLAN.md.
No code is written here — each step is an action with a reference.
Follow phases in order; each phase has hard dependencies on the one before it.

---

## Before You Start — What You Need

- Proxmox VE node running and accessible on your LAN
- GitHub account with the `k8s-planning` repo created
- A machine (laptop/desktop) with internet access for local tooling
- A block of free IPs on your LAN for VMs and MetalLB (e.g. 10 IPs reserved in your router's DHCP exclusion range)

---

## Phase 0: Local Tooling

Install all CLI tools on your local machine before touching Proxmox.

**Step 0.1 — Install Terraform via tfenv (version manager)**
> tfenv lets you pin the exact Terraform version per project, avoiding version drift.
> Docs: https://github.com/tfutils/tfenv

**Step 0.2 — Install Ansible via pip**
> Install with `pip install --user ansible`. Avoid distro packages — they lag behind.
> Docs: https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html

**Step 0.3 — Install Ansible Galaxy collections**
> Install `kubernetes.core` and `community.general` collections.
> These are needed for interacting with the k8s API and Proxmox inventory from Ansible.
> Docs: https://docs.ansible.com/ansible/latest/collections_guide/collections_installing.html

**Step 0.4 — Install kubectl**
> Install the version that matches the Kubernetes version you plan to run (e.g. 1.30).
> Docs: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/

**Step 0.5 — Install Helm**
> Helm is used to install kube-prometheus-stack and ingress-nginx.
> Docs: https://helm.sh/docs/intro/install/

**Step 0.6 — Generate an SSH key pair for Ansible**
> This key will be injected into every VM via cloud-init. Ansible uses it to connect.
> Keep the private key safe — it will also be stored as a GitHub Actions secret later.
> Use `ssh-keygen`, choose a strong key type (ed25519).

---

## Phase 1: Proxmox Preparation

**Step 1.1 — Create a dedicated Proxmox user for Terraform**
> Do not use root. Create a user (e.g. `terraform@pve`) with the minimum required roles.
> Required privileges: VM.Allocate, VM.Clone, VM.Config.*, Datastore.AllocateSpace, SDN.Use.
> Docs: https://pve.proxmox.com/wiki/User_Management

**Step 1.2 — Create a Proxmox API token for that user**
> Proxmox UI → Datacenter → Permissions → API Tokens → Add.
> Note the Token ID and Secret — the secret is only shown once.
> Docs: https://pve.proxmox.com/wiki/Proxmox_VE_API#API_Tokens

**Step 1.3 — Download the Ubuntu 24.04 LTS cloud image onto Proxmox**
> SSH into Proxmox, download the official Ubuntu cloud image (.img format).
> Ubuntu cloud images: https://cloud-images.ubuntu.com/noble/current/
> Get the `noble-server-cloudimg-amd64.img` file.

**Step 1.4 — Create a base VM template on Proxmox**
> This is done once. Every worker and control plane VM will be a clone of this template.
> Steps: create VM → remove default disk → import cloud image as disk → add cloud-init drive → enable QEMU guest agent → set CPU/memory defaults → convert to template.
> Full walkthrough: https://pve.proxmox.com/wiki/Cloud-Init_Support
> Also reference: https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/guides/cloud-init.md

**Step 1.5 — Install the QEMU guest agent inside the template VM before converting**
> Before converting to template, boot the VM once, install `qemu-guest-agent`, enable it as a service, then shut down and convert.
> The guest agent enables Proxmox to report the VM's IP address to Terraform, which is needed to hand IPs to Ansible without hardcoding them.
> Docs: https://pve.proxmox.com/wiki/Qemu-guest-agent

**Step 1.6 — Plan and reserve your IP ranges**
> Decide on three ranges before writing any Terraform:
> - Control plane VM IP (1 static IP, e.g. 192.168.1.100)
> - Worker VM IPs (e.g. 192.168.1.101–192.168.1.110, reserved in your router)
> - MetalLB pool (e.g. 192.168.1.200–192.168.1.220, reserved in your router — these are the IPs k8s LoadBalancer Services will get)
> This avoids DHCP conflicts later. Set these as exclusions in your router/DHCP server.

**Step 1.7 — Verify Proxmox API is reachable and token works**
> Test the API token with a curl command against the Proxmox REST API before writing any Terraform.
> API reference: https://pve.proxmox.com/pve-docs/api-viewer/
> A successful response from `GET /api2/json/nodes` confirms auth is working.

---

## Phase 2: Terraform Cloud State Backend

> Terraform state tracks every resource Terraform manages. It must be stored remotely so GitHub Actions can access it across runs, and locked so two workflows don't conflict.

**Step 2.1 — Create a Terraform Cloud account**
> Sign up at https://app.terraform.io — free tier is sufficient.

**Step 2.2 — Create an organization in Terraform Cloud**
> Name it something identifiable (e.g. your GitHub username).

**Step 2.3 — Create a workspace set to CLI-driven mode**
> CLI-driven means Terraform runs locally or in GitHub Actions — not inside HCP.
> Name it `k8s-proxmox` or similar.
> Docs: https://developer.hashicorp.com/terraform/cloud-docs/workspaces/creating

**Step 2.4 — Generate a Terraform Cloud API token**
> Account Settings → Tokens → Create an API token.
> Store this securely — you'll need it for local Terraform runs and as a GitHub secret.
> Docs: https://developer.hashicorp.com/terraform/cloud-docs/users-teams-organizations/api-tokens

**Step 2.5 — Configure the Terraform CLI to authenticate with Terraform Cloud**
> Run `terraform login` locally — this stores the token in your local credential file.
> Docs: https://developer.hashicorp.com/terraform/cli/commands/login

---

## Phase 3: Self-Hosted GitHub Actions Runner

> **This is critical and often overlooked.** GitHub-hosted runners run on GitHub's infrastructure — they have no network path to your home Proxmox server. You need a self-hosted runner that lives on your LAN.

**Step 3.1 — Create a dedicated runner VM on Proxmox**
> Clone your Ubuntu template to create a small VM (2 CPU, 2 GB RAM is enough).
> This VM does not join the k8s cluster — it is purely the CI/CD execution environment.
> It must have network access to: Proxmox API, all k8s node IPs, and the internet (GitHub API).

**Step 3.2 — Install the GitHub Actions runner software on that VM**
> GitHub repo → Settings → Actions → Runners → New self-hosted runner.
> Follow the Linux installation steps — download the runner package, configure with your repo URL and token, install as a service.
> Docs: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners

**Step 3.3 — Install all required tools on the runner VM**
> The runner VM needs: Terraform (same version as local), Ansible, kubectl, Helm, git, curl, jq.
> jq is needed for parsing Terraform state output and Prometheus API responses in workflows.

**Step 3.4 — Copy the Ansible SSH private key onto the runner VM**
> The runner needs the private key (from Step 0.6) to SSH into k8s VMs when running Ansible.
> Store it at a fixed path (e.g. `~/.ssh/ansible_key`) and restrict permissions (`chmod 600`).
> This key also gets stored as a GitHub Actions secret for the workflow to write it at runtime.

**Step 3.5 — Verify the runner appears as online in GitHub**
> GitHub repo → Settings → Actions → Runners — the runner should show as "Idle".
> Tag it with a label (e.g. `proxmox-lan`) so workflows can target it specifically with `runs-on: [self-hosted, proxmox-lan]`.

---

## Phase 4: Repository Structure

**Step 4.1 — Create the directory skeleton in your k8s-planning repo**
> Create these empty directories with a `.gitkeep` placeholder so they appear in Git:
> `terraform/`, `ansible/inventory/`, `ansible/roles/`, `ansible/group_vars/`, `k8s/namespaces/`, `k8s/monitoring/`, `k8s/ingress/`, `k8s/apps/`, `argocd/apps/`, `.github/workflows/`

**Step 4.2 — Create a `.gitignore`**
> Exclude: `*.tfstate`, `*.tfstate.backup`, `.terraform/`, `*.tfvars` (contains secrets), `ansible/inventory/hosts.ini` (generated at runtime), `kubeconfig`.

**Step 4.3 — Create a `terraform/versions.tf`**
> Declare the required Terraform version and the `bpg/proxmox` provider with a pinned version.
> Find the latest version at: https://registry.terraform.io/providers/bpg/proxmox/latest
> Also declare the Terraform Cloud backend block pointing to your organization and workspace from Phase 2.

---

## Phase 5: Terraform — Infrastructure Definition

### 5a: Node Capacity Configuration (Multi-Node Placement)

> Before writing any Terraform, you must define how workers are distributed across your Proxmox nodes. This config drives all placement decisions at deploy time.

**Step 5a.1 — Inventory your Proxmox nodes and their practical worker capacity**
> For each Proxmox node (pve1, pve2, pve3, pve4...), determine the maximum number of worker VMs it can comfortably host given its physical RAM, CPU cores, and storage.
> This is NOT Proxmox's hard limit — it is YOUR defined ceiling. Example: a node with 64 GB RAM running other VMs might have practical capacity for 3 workers at 8 GB each.
> Write these limits down before proceeding.

**Step 5a.2 — Create `terraform/node_capacities.json`**
> Create a JSON file in the repo (committed to Git) that maps each Proxmox node name to its max worker count.
> Example structure: `{ "pve1": 3, "pve2": 6, "pve3": 4, "pve4": 2 }`
> This file is the single source of truth for placement decisions. Changing a node's capacity is a Git commit — it is auditable and versioned.
> This file is READ by the deploy-worker GitHub Actions workflow before calling Terraform. Terraform itself does not read it — it just receives the already-decided target node as a variable.

**Step 5a.3 — Decide on and document the worker naming convention**
> Workers must be named to encode the Proxmox node they live on.
> Recommended pattern: `worker-{proxmox-node}-{zero-padded-sequence}`
> Examples: `worker-pve2-01`, `worker-pve2-02`, `worker-pve1-01`
> Document this in a comment in `terraform/worker.tf` so the pattern is obvious when reading Terraform.
> This naming is how the placement algorithm counts current workers per node — it parses the node name out of the VM name, so the pattern must be consistent.

**Step 5a.4 — Understand the placement selection algorithm**
> The deploy-worker workflow will run this logic before every Terraform apply:
>
> 1. Read `terraform/node_capacities.json` — produces a map of `{node: max}`
> 2. For each node in the map, call the Proxmox API: `GET /api2/json/nodes/{node}/qemu`
>    - Filter the returned VM list to count only VMs whose names match `worker-{node}-*`
>    - This gives `current_count` per node
>    - Proxmox API reference: https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu
> 3. For each node: `remaining = max - current_count`
> 4. Select the node with the **highest remaining value**
> 5. Tiebreak: if two nodes have equal remaining, pick the one with the higher `max` (more capable host)
> 6. If all nodes have `remaining = 0`: fail the workflow immediately with a clear error message — do not proceed to Terraform
> 7. Derive the new worker name: find the highest existing sequence number for that node from the Proxmox API response, increment by 1, zero-pad to 2 digits

**Step 5a.5 — Verify the Proxmox API is queryable from the self-hosted runner**
> From the runner VM (Phase 3), use curl to call `GET /api2/json/nodes/{node}/qemu` with your API token.
> Confirm you get a JSON array of VM objects back, each with a `name` field.
> This is the exact call the workflow will make — confirming it works here prevents silent failures later.
> Proxmox API auth reference: https://pve.proxmox.com/wiki/Proxmox_VE_API#Authentication

---

### 5b: Terraform File Definitions

**Step 5.1 — Write `terraform/variables.tf`**
> Define all input variables: Proxmox API URL, token ID, token secret (marked sensitive), template name, control plane node name, control plane specs (CPU/memory/disk), SSH public key content, VM network bridge name.
> **The workers variable is a map of objects** — key is the worker name (e.g. `worker-pve2-01`), value contains: `node` (Proxmox node name), `memory` (MB), `cores`, `disk_size`.
> Remove any `worker_count` simple integer variable — the map is the new interface.
> Do not hardcode values — every environment-specific setting is a variable.

**Step 5.2 — Write `terraform/main.tf`**
> Configure the `bpg/proxmox` provider using variables for the API URL and credentials.
> Reference: https://registry.terraform.io/providers/bpg/proxmox/latest/docs#argument-reference

**Step 5.3 — Write `terraform/controlplane.tf`**
> Define the `proxmox_virtual_environment_vm` resource for the control plane node.
> Configure: clone from your template, set CPU/memory, inject SSH public key via cloud-init, set hostname via cloud-init, assign static IP.
> The control plane always goes on a specific designated node — hardcode this or use a dedicated variable.
> Reference: https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm

**Step 5.4 — Write `terraform/worker.tf`**
> Define the worker VM resource using `for_each` over the workers map variable.
> Each iteration uses `each.key` as the VM name (e.g. `worker-pve2-01`) and `each.value.node` as the target Proxmox node.
> Each worker's memory and cores come from `each.value.memory` and `each.value.cores` — this is what makes individual vertical scaling possible without touching other workers.
> **Why map over count:** with `count`, removing worker index 1 causes Terraform to shift and want to recreate workers 2, 3, etc. With `for_each` on a map, adding or removing `worker-pve2-02` only touches that one resource.
> Reference: https://developer.hashicorp.com/terraform/language/meta-arguments/for_each

**Step 5.5 — Write `terraform/outputs.tf`**
> Output the control plane IP and a map of worker names to their IPs.
> Also output a map of worker names to their Proxmox node — useful for the remove-worker workflow to confirm which node to target.
> These outputs are consumed by Ansible to build the inventory dynamically.

**Step 5.6 — Create a `terraform/terraform.tfvars` (local only, gitignored)**
> Populate with your actual Proxmox URL, token ID, token secret, SSH public key, and the initial workers map (your first worker entry).
> This file must never be committed — it contains secrets.
> For GitHub Actions, the workers map is passed as a JSON environment variable.

**Step 5.7 — Run `terraform init` locally**
> Downloads the bpg/proxmox provider and connects to Terraform Cloud as the state backend.
> Verify it authenticates successfully and the workspace is initialised.

**Step 5.8 — Run `terraform plan` locally**
> Review the execution plan — confirm it will create the control plane VM and the first worker VM on the correct Proxmox node.
> Check that the worker name in the plan matches your naming convention.
> Fix any validation errors before applying.

**Step 5.9 — Run `terraform apply` locally (first manual apply)**
> This is the only manual Terraform apply — after this, all applies go through GitHub Actions.
> Confirm VMs appear in the Proxmox UI under the correct node.
> Confirm IPs appear in `terraform output`.
> Confirm the worker VM name in Proxmox matches the naming convention.

---

## Phase 6: Ansible — Cluster Bootstrap

**Step 6.1 — Generate the Ansible inventory from Terraform output**
> Run `terraform output -json` and use `jq` to produce an `ansible/inventory/hosts.ini` file with the correct groups (`[controlplane]`, `[workers]`, `[k8s:children]`).
> This step will later be automated in GitHub Actions — for now do it manually for the bootstrap.

**Step 6.2 — Write `ansible/group_vars/all.yml`**
> Define shared variables: Kubernetes version (e.g. `1.30`), pod network CIDR (`192.168.0.0/16` for Calico), container runtime (containerd), Ansible SSH user (ubuntu), SSH key path.

**Step 6.3 — Write and run the `common` role**
> This role targets all nodes. Steps it must perform:
> - Disable swap permanently (kubeadm requirement)
> - Load `overlay` and `br_netfilter` kernel modules
> - Set sysctl params: `net.bridge.bridge-nf-call-iptables=1`, `net.ipv4.ip_forward=1`
> - Install dependencies: apt-transport-https, curl, gnupg, ca-certificates
> Run: `ansible-playbook -i inventory/hosts.ini site.yml --tags common`
> Reference: https://kubernetes.io/docs/setup/production-environment/container-runtimes/

**Step 6.4 — Write and run the `containerd` role**
> Install containerd from the Docker apt repository (more up-to-date than Ubuntu's package).
> After install, generate the default config and edit it to set `SystemdCgroup = true` — this is required for kubeadm.
> Restart containerd after config change.
> Reference: https://docs.docker.com/engine/install/ubuntu/

**Step 6.5 — Write and run the `kubeadm` role**
> Add the Kubernetes apt repository (use the versioned repo, e.g. `pkgs.k8s.io/core:/stable:/v1.30/deb/`).
> Install `kubeadm`, `kubelet`, `kubectl` at the pinned version.
> Hold their versions with `apt-mark hold` to prevent accidental upgrades.
> Enable and start the `kubelet` service.
> Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/

**Step 6.6 — Write and run the `controlplane` role**
> Run `kubeadm init` with your pod network CIDR and the control plane's advertised IP.
> Copy the generated `admin.conf` kubeconfig to the ubuntu user's home directory.
> Save the `kubeadm join` command output to a file — worker nodes need this.
> Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/

**Step 6.7 — Install Calico CNI**
> Apply the Calico operator manifest via kubectl on the control plane node.
> Then apply the Calico custom resource to configure the pod network CIDR you used in kubeadm init.
> Wait for all Calico pods to reach Running state before proceeding.
> Reference: https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises

**Step 6.8 — Write and run the `worker` role**
> Using the join command captured in Step 6.6, run `kubeadm join` on each worker node.
> Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#join-nodes

**Step 6.9 — Verify the cluster**
> From the control plane (or locally with the kubeconfig), run `kubectl get nodes`.
> All nodes should show `Ready`. This may take 1–2 minutes after CNI is installed.
> If any node stays `NotReady`, check `kubectl describe node <name>` and Calico pod logs.

**Step 6.10 — Copy the kubeconfig to your local machine**
> Copy `/etc/kubernetes/admin.conf` from the control plane to `~/.kube/config` locally.
> Test with `kubectl get nodes` from your local machine.
> Also base64-encode this file — it becomes a GitHub Secret for Actions to use.

---

## Phase 7: Networking Add-ons

**Step 7.1 — Install MetalLB**
> Apply the MetalLB manifest via kubectl. Wait for all MetalLB pods Running.
> Create an `IPAddressPool` custom resource using the IP range you reserved in Step 1.6.
> Create an `L2Advertisement` custom resource to enable Layer 2 mode (works on home LAN without BGP).
> Reference: https://metallb.universe.tf/installation/
> L2 mode guide: https://metallb.universe.tf/configuration/#layer-2-configuration

**Step 7.2 — Install ingress-nginx via Helm**
> Add the ingress-nginx Helm repo and install to the `ingress-nginx` namespace.
> After install, verify a `LoadBalancer` service is created and MetalLB assigns it an IP from your pool.
> Reference: https://kubernetes.github.io/ingress-nginx/deploy/#quick-start

**Step 7.3 — Verify end-to-end ingress**
> Deploy a simple test pod (e.g. nginx) with an Ingress resource pointing to it.
> Confirm you can reach it from your LAN browser via the MetalLB IP.
> Delete the test pod after verification.

---

## Phase 8: GitOps — ArgoCD

**Step 8.1 — Install ArgoCD via Helm**
> Add the ArgoCD Helm repo and install to the `argocd` namespace.
> Reference: https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/
> Helm chart: https://artifacthub.io/packages/helm/argo/argo-cd

**Step 8.2 — Expose the ArgoCD UI**
> Create an Ingress resource for the ArgoCD server service, pointing to your ingress-nginx.
> Or port-forward temporarily: `kubectl port-forward svc/argocd-server -n argocd 8080:443`

**Step 8.3 — Retrieve the initial admin password and log in**
> The password is stored in a Kubernetes secret named `argocd-initial-admin-secret` in the `argocd` namespace.
> Log in and immediately change the admin password.
> Docs: https://argo-cd.readthedocs.io/en/stable/getting_started/#4-login-using-the-cli

**Step 8.4 — Connect ArgoCD to your GitHub repository**
> In ArgoCD UI: Settings → Repositories → Connect Repo.
> Use HTTPS with a GitHub PAT or SSH — SSH is preferred for private repos.
> Docs: https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/

**Step 8.5 — Create the root ArgoCD Application (App-of-Apps pattern)**
> Create an ArgoCD `Application` resource that points to your `argocd/apps/` directory.
> ArgoCD will then discover and sync all Application definitions inside that directory automatically.
> This means adding a new app to the cluster becomes a Git commit — no manual ArgoCD UI steps.
> Reference: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/

**Step 8.6 — Test the GitOps loop**
> Add a simple `Application` YAML to `argocd/apps/` pointing to a test manifest in `k8s/apps/`.
> Commit and push. ArgoCD should detect the change and sync within 3 minutes (default poll interval).
> Verify in the UI that the app shows Synced/Healthy.

---

## Phase 9: Monitoring Stack (via GitOps)

> All monitoring components are deployed via ArgoCD from this point — not with manual helm installs.

**Step 9.1 — Create the monitoring namespace manifest**
> Add a `k8s/namespaces/monitoring.yaml` file defining the `monitoring` namespace.
> Commit and push — ArgoCD syncs it.

**Step 9.2 — Create a kube-prometheus-stack HelmRelease definition**
> In `k8s/monitoring/`, create an ArgoCD `Application` manifest (or Flux `HelmRelease` if using Flux) that references the `prometheus-community/kube-prometheus-stack` Helm chart.
> Configure values: enable persistent storage for Prometheus (so metrics survive pod restarts), set Grafana admin password via a k8s Secret reference, enable node-exporter DaemonSet.
> Chart reference: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

**Step 9.3 — Commit and let ArgoCD deploy the monitoring stack**
> Push the manifest. ArgoCD installs the full kube-prometheus-stack.
> Wait for all pods in the `monitoring` namespace to reach Running/Ready.
> This includes: prometheus, alertmanager, grafana, node-exporter (one per node), kube-state-metrics.

**Step 9.4 — Expose Grafana via Ingress**
> Add an Ingress resource for the Grafana service to your `k8s/monitoring/` directory.
> Access Grafana in your browser via the MetalLB IP or a hostname.

**Step 9.5 — Import key Grafana dashboards**
> Import these community dashboards via Grafana UI (Dashboards → Import → enter ID):
> - Node Exporter Full: ID `1860` — per-node CPU, RAM, disk, network
> - Kubernetes Cluster Overview: ID `7249`
> - These give you the visibility to verify the metrics AlertManager will use for scaling decisions.

**Step 9.6 — Verify node memory metrics are appearing correctly**
> In Grafana, open the Node Exporter Full dashboard and confirm all cluster nodes appear.
> Verify the RAM usage metrics match what you expect from the Proxmox VM config.
> Run the PromQL queries from the plan in Grafana's Explore panel to confirm they return data:
> `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100`

---

## Phase 10: AlertManager Rules and Webhook Adapter

**Step 10.1 — Write the three Prometheus alert rules**
> Create a `PrometheusRule` custom resource in `k8s/monitoring/` with the three alert definitions:
> - `NodeMemoryPressure`: single worker RAM > 75% for 5 minutes
> - `NodeMemoryLow`: single worker RAM < 30% for 15 minutes
> - `ClusterHighLoad`: ALL workers simultaneously > 75% RAM
> Reference for PrometheusRule CRD: https://prometheus-operator.dev/docs/user-guides/alerting/

**Step 10.2 — Deploy the alertmanager-webhook-adapter**
> AlertManager's `webhook_config` sends a fixed Alertmanager JSON payload — it cannot natively inject custom fields like node names into a GitHub-compatible `repository_dispatch` body.
> The adapter receives the AlertManager webhook, extracts the node label from the alert, and reformats the body for GitHub's API.
> Deploy it as a `Deployment` + `Service` in the `monitoring` namespace via a manifest in `k8s/monitoring/`.
> Reference: https://github.com/prometheus-community/alertmanager-webhook-adapter
> Alternatively, a small custom Deployment with a 20-line Python/Go HTTP server works fine for this.

**Step 10.3 — Configure AlertManager routes and receivers**
> Edit the AlertManager configuration (via kube-prometheus-stack Helm values or a standalone `AlertmanagerConfig` CRD) to:
> - Route `NodeMemoryPressure` alerts → webhook adapter (which forwards as `memory-pressure` dispatch event)
> - Route `NodeMemoryLow` alerts → webhook adapter (forwards as `scale-in` dispatch event)
> - Route `ClusterHighLoad` alerts → webhook adapter (forwards as `scale-out` dispatch event)
> Reference: https://prometheus.io/docs/alerting/latest/configuration/#webhook_config
> AlertmanagerConfig CRD reference: https://prometheus-operator.dev/docs/user-guides/alerting/#using-alertmanagerconfig

**Step 10.4 — Create a GitHub PAT for the webhook adapter to use**
> The adapter needs to call GitHub's API. Create a GitHub PAT with `repo` scope (specifically `workflow` permission to trigger dispatches).
> Store it as a Kubernetes Secret in the `monitoring` namespace.
> The adapter reads it from the secret at runtime — never hardcode it.
> GitHub PAT docs: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens

**Step 10.5 — Test AlertManager routing manually**
> Use `amtool` (AlertManager CLI) or the AlertManager UI to fire a test alert and confirm:
> - The alert routes to the correct receiver
> - The webhook adapter receives it
> - A `repository_dispatch` event appears in your GitHub repo's Actions tab
> amtool docs: https://prometheus.io/docs/alerting/latest/management_api/

---

## Phase 11: GitHub Actions Secrets

**Step 11.1 — Store all required secrets in GitHub Actions**
> GitHub repo → Settings → Secrets and variables → Actions → New repository secret.
> Add each of the following:
> - `TF_API_TOKEN` — Terraform Cloud API token (from Phase 2.4)
> - `PROXMOX_API_TOKEN_ID` — Proxmox token ID (from Phase 1.2)
> - `PROXMOX_API_TOKEN_SECRET` — Proxmox token secret (from Phase 1.2)
> - `KUBECONFIG_B64` — base64-encoded kubeconfig (from Phase 6.10)
> - `ANSIBLE_SSH_PRIVATE_KEY` — the Ansible SSH private key (from Phase 0.6)
> - `GH_DISPATCH_TOKEN` — GitHub PAT for repository_dispatch (from Phase 10.4, same token or a separate one)

**Step 11.2 — Configure Terraform Cloud workspace to accept remote variables**
> In Terraform Cloud, set the workspace variables for Proxmox credentials as environment variables (marked sensitive).
> This keeps secrets out of your workflow YAML files entirely.
> Docs: https://developer.hashicorp.com/terraform/cloud-docs/workspaces/variables

---

## Phase 12: GitHub Actions Workflows

**Step 12.1 — Write the `deploy-worker` workflow**
> File: `.github/workflows/deploy-worker.yml`
> Trigger: `repository_dispatch` with event type `scale-out`
> The workflow must perform these steps in order:
>
> **Pre-Terraform: Node Placement Selection**
> - Read `terraform/node_capacities.json` using `jq` to get the max capacity per node
> - For each Proxmox node in the map, call the Proxmox REST API: `GET /api2/json/nodes/{node}/qemu`
>   - Authenticate using `PROXMOX_API_TOKEN_ID` and `PROXMOX_API_TOKEN_SECRET` secrets
>   - Filter the response to count only VMs whose `name` field matches `worker-{node}-*`
>   - Tool: curl + jq. Reference: https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu
> - Calculate `remaining = max - current_count` for each node
> - Select the node with the highest remaining; tiebreak on highest max
> - If all nodes are at max: fail the step with `exit 1` and a clear message — do not proceed
> - Derive the new worker name: query existing VMs on the selected node, find highest sequence, increment
>
> **Terraform Apply**
> - `terraform init` with Terraform Cloud backend
> - Read the current workers map from `terraform show -json`
> - Add the new worker entry (name, selected node, default memory/cores) to the map
> - `terraform apply` passing the updated workers map — Terraform creates one new VM on the selected node
> - Capture the new VM's IP from `terraform output`
>
> **Ansible Join**
> - Write the new VM's IP to a temporary inventory file
> - Run Ansible `site.yml` targeting only the new worker (common → containerd → kubeadm → worker roles)
>
> **Verify**
> - Poll `kubectl get nodes` until the new node appears in `Ready` state (timeout after 5 minutes)
>
> Docs for repository_dispatch trigger: https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#repository_dispatch

**Step 12.2 — Write the `remove-worker` workflow**
> File: `.github/workflows/remove-worker.yml`
> Trigger: `repository_dispatch` with event type `scale-in`
> The `client_payload` will contain the k8s node name from AlertManager.
> The workflow must:
> - Read `github.event.client_payload.node` to get the target k8s node name
> - Re-query the Prometheus HTTP API to confirm the node is STILL below 30% RAM (stale alert guard)
>   - If it has recovered, exit cleanly without making any changes
>   - Prometheus HTTP API: https://prometheus.io/docs/prometheus/latest/querying/api/
> - Parse the Proxmox node name from the k8s node name using the naming convention (e.g. `worker-pve2-01` → Proxmox node is `pve2`)
> - `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
> - `kubectl delete node <node>`
> - Read current workers map from `terraform show -json`, remove the entry for this worker
> - `terraform apply` with the updated map — Terraform destroys only that VM on its Proxmox node
> - Verify the node no longer appears in `kubectl get nodes`

**Step 12.3 — Write the `resize-worker` workflow**
> File: `.github/workflows/resize-worker.yml`
> Trigger: `repository_dispatch` with event type `memory-pressure`
> The workflow must:
> - Read the target node name from `client_payload.node`
> - Query Terraform state (via `terraform show -json`) to find the current memory allocation for that VM
> - Decision gate:
>   - If current RAM < 16 GB: cordon, drain, terraform apply with increased memory (+4 GB step), wait for node Ready, uncordon
>   - If current RAM >= 16 GB: call the GitHub API to fire a `scale-out` repository_dispatch event (trigger the deploy-worker workflow)
> Terraform show docs: https://developer.hashicorp.com/terraform/cli/commands/show

---

## Phase 13: End-to-End Verification

**Step 13.1 — Test the scale-out path**
> SSH into one worker. Install `stress-ng` (`apt install stress-ng`).
> Run `stress-ng --vm 1 --vm-bytes 90%` on ALL workers simultaneously to trigger `ClusterHighLoad`.
> Watch AlertManager UI — confirm the alert fires after 5 minutes.
> Watch GitHub Actions tab — confirm `deploy-worker` workflow is triggered.
> Watch Proxmox UI — confirm a new VM is being created.
> Watch `kubectl get nodes --watch` — confirm the new node joins and reaches `Ready`.
> Stop the stress test. Confirm the alert resolves.

**Step 13.2 — Test the resize path**
> Run `stress-ng --vm 1 --vm-bytes 80%` on a SINGLE worker to trigger `NodeMemoryPressure`.
> Confirm after 5 minutes: AlertManager fires, webhook adapter forwards, `resize-worker` workflow triggers.
> Confirm workflow checks current RAM, determines it is under 16 GB.
> Confirm node is cordoned → drained → VM memory increased in Proxmox → node returns Ready → uncordoned.
> Check `terraform show` to confirm the new memory value is reflected in state.

**Step 13.3 — Test the 16 GB cap → horizontal path**
> Manually update Terraform to set a single worker's memory to 16 GB and apply it.
> Re-run the stress test on that worker.
> Confirm `resize-worker` workflow detects the 16 GB cap and fires a `scale-out` dispatch instead.
> Confirm `deploy-worker` runs and a new worker is added.

**Step 13.4 — Test the scale-in path**
> With excess workers running (from previous tests), let them idle.
> `NodeMemoryLow` fires after 15 minutes of <30% RAM.
> Confirm `remove-worker` workflow drains and removes the least-loaded node.
> Confirm Proxmox VM is destroyed.
> Confirm `terraform state list` no longer includes that VM.

**Step 13.5 — Verify ArgoCD reconciles after every node change**
> After each scale event, confirm ArgoCD shows the cluster state as Synced/Healthy.
> Node changes don't affect ArgoCD applications directly, but DaemonSets (node-exporter, Calico) should automatically extend to new nodes — verify this in Grafana after a scale-out.

---

## Ongoing — What to Monitor in Grafana

Once running, these are the dashboards and panels to watch:

| Panel | What it tells you |
|---|---|
| Node RAM usage % | Triggers for resize and scale-in decisions |
| Node count over time | Confirms scale-out and scale-in events happened |
| AlertManager alerts active | Which rules are currently firing |
| GitHub Actions via webhook adapter logs | Whether dispatches are being sent |
| Calico pod count per node | Confirms CNI is healthy on new nodes |
| kube-state-metrics: node conditions | Shows NotReady events during drain/resize |

---

## Reference Links (Consolidated)

| Step | Resource |
|---|---|
| Proxmox API tokens | https://pve.proxmox.com/wiki/Proxmox_VE_API#API_Tokens |
| Proxmox cloud-init | https://pve.proxmox.com/wiki/Cloud-Init_Support |
| QEMU guest agent | https://pve.proxmox.com/wiki/Qemu-guest-agent |
| bpg/proxmox provider | https://registry.terraform.io/providers/bpg/proxmox/latest/docs |
| bpg/proxmox VM data source | https://registry.terraform.io/providers/bpg/proxmox/latest/docs/data-sources/virtual_environment_vms |
| Proxmox list VMs per node API | https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu |
| Terraform for_each | https://developer.hashicorp.com/terraform/language/meta-arguments/for_each |
| Terraform Cloud workspaces | https://developer.hashicorp.com/terraform/cloud-docs/workspaces/creating |
| GitHub self-hosted runners | https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners |
| kubeadm install | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/ |
| kubeadm init | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/ |
| containerd install | https://docs.docker.com/engine/install/ubuntu/ |
| Calico CNI | https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises |
| MetalLB L2 | https://metallb.universe.tf/configuration/#layer-2-configuration |
| ingress-nginx | https://kubernetes.github.io/ingress-nginx/deploy/ |
| ArgoCD Helm install | https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/ |
| ArgoCD App-of-Apps | https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/ |
| kube-prometheus-stack | https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack |
| PrometheusRule CRD | https://prometheus-operator.dev/docs/user-guides/alerting/ |
| AlertManager config | https://prometheus.io/docs/alerting/latest/configuration/ |
| AlertmanagerConfig CRD | https://prometheus-operator.dev/docs/user-guides/alerting/#using-alertmanagerconfig |
| alertmanager-webhook-adapter | https://github.com/prometheus-community/alertmanager-webhook-adapter |
| Prometheus HTTP API | https://prometheus.io/docs/prometheus/latest/querying/api/ |
| GitHub repository_dispatch | https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event |
| GitHub Actions triggers | https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows |
| GitHub PAT | https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens |
| Node Exporter Full dashboard | https://grafana.com/grafana/dashboards/1860 |
| K8s Cluster Overview dashboard | https://grafana.com/grafana/dashboards/7249 |
