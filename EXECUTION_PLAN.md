# Execution Plan — K8s Cluster on Proxmox

This document is the step-by-step build guide derived from PLAN.md.
No code is written here — each step is an action with a reference.
Follow phases in order; each phase has hard dependencies on the one before it.

---

## Unavoidably Manual Steps (one-time human actions)

These cannot be automated because they are either initial credentials that must exist before automation can run, or human decisions with no computable answer:

- Creating the Proxmox API user and token (chicken-and-egg — the token is what automation uses)
- Deciding IP ranges (Step 1.5 — your router/LAN layout)
- Creating the Backblaze B2 account and bucket (web signup — offsite backup target)
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

**Step 0.1 — Install all developer machine tools**
> Install the following on every machine you work from. Install methods vary by distro — see the table below.
> - `tofuenv` + OpenTofu — IaC, version-pinned per project. Docs: https://github.com/tofuutils/tofuenv
> - `packer` — builds the Proxmox VM template. Docs: https://developer.hashicorp.com/packer/install
> - `kubectl` — interacts with the cluster from your machine. Docs: https://kubernetes.io/docs/tasks/tools/
> - `helm` — used for any one-off chart operations. Docs: https://helm.sh/docs/intro/install/
> - `argocd` CLI — connects ArgoCD to the GitHub repo during bootstrap. Docs: https://argo-cd.readthedocs.io/en/stable/cli_installation/
> - `velero` CLI — verifies backups in Phase 13. Docs: https://velero.io/docs/latest/basic-install/
> - `mc` (MinIO client) — verifies MinIO bucket contents in Phase 13. Docs: https://min.io/docs/minio/linux/reference/minio-mc.html
> - `bao` (OpenBao CLI) — initialises, unseals, and loads secrets into OpenBao. Docs: https://openbao.org/docs/install/
> - `ansible` — install via pip on all distros (distro-packaged versions lag behind). Docs: https://docs.ansible.com/ansible/latest/installation_guide/
> - `ansible-galaxy` collections: `kubernetes.core`, `community.general`
> - `jq` — parses Terraform and Proxmox JSON output in workflows
> - `git`, `curl`, `gh` (GitHub CLI) — repo ops and GitHub API calls. gh: https://cli.github.com/
>
> **Install methods by distro:**
>
> | Tool | Ubuntu / Debian | Fedora / RHEL / Rocky | Arch / Manjaro | macOS |
> |---|---|---|---|---|
> | `tofuenv` | GitHub releases (manual) or `brew install tofuenv` | GitHub releases (manual) or `brew install tofuenv` | `yay -S tofuenv` or `brew install tofuenv` | `brew install tofuenv` |
> | `packer` | HashiCorp apt repo or `brew tap hashicorp/tap && brew install hashicorp/tap/packer` | HashiCorp dnf repo or `brew tap hashicorp/tap && brew install hashicorp/tap/packer` | `yay -S packer` or `brew tap hashicorp/tap && brew install hashicorp/tap/packer` | `brew tap hashicorp/tap && brew install hashicorp/tap/packer` |
> | `kubectl` | Kubernetes apt repo (`pkgs.k8s.io`) or `brew install kubectl` | Kubernetes dnf repo (`pkgs.k8s.io`) or `brew install kubectl` | `pacman -S kubectl` or `brew install kubectl` | `brew install kubectl` |
> | `helm` | Helm install script or apt repo or `brew install helm` | Helm install script or dnf or `brew install helm` | `pacman -S helm` or `brew install helm` | `brew install helm` |
> | `argocd` CLI | GitHub releases binary or `brew install argocd` | GitHub releases binary or `brew install argocd` | `yay -S argocd-cli` or `brew install argocd` | `brew install argocd` |
> | `velero` CLI | GitHub releases binary or `brew install velero` | GitHub releases binary or `brew install velero` | `yay -S velero-bin` or `brew install velero` | `brew install velero` |
> | `mc` | Binary download or `brew install minio/stable/mc` | Binary download or `brew install minio/stable/mc` | `pacman -S minio-client` or `brew install minio/stable/mc` | `brew install minio/stable/mc` |
> | `bao` | `.deb` from GitHub releases or `brew install openbao` | `.rpm` from GitHub releases or `brew install openbao` | `yay -S openbao-bin` or `brew install openbao` | `brew install openbao` |
> | `ansible` | `pip install ansible` | `pip install ansible` | `pip install ansible` | `pip install ansible` |
> | `jq` | `apt install jq` or `brew install jq` | `dnf install jq` or `brew install jq` | `pacman -S jq` or `brew install jq` | `brew install jq` |
> | `git` | `apt install git` or `brew install git` | `dnf install git` or `brew install git` | `pacman -S git` or `brew install git` | `brew install git` |
> | `curl` | `apt install curl` | `dnf install curl` | `pacman -S curl` | built-in |
> | `gh` | GitHub apt repo or `brew install gh` | GitHub dnf repo or `brew install gh` | `pacman -S github-cli` or `brew install gh` | `brew install gh` |
>
> All Linux distros: `brew install` (Homebrew for Linux) works as an alternative for most tools — install it once via `curl` if not present. The script will warn before installing brew. The table lists the native package manager first; where brew is also shown, either works.
> Arch users additionally have `yay -S` (or any AUR helper) for packages not in the official repos.
> Fedora/RHEL users: HashiCorp maintains a dnf repo (`rpm.releases.hashicorp.com`) for packer; the Kubernetes project maintains `pkgs.k8s.io` for kubectl.
> All distros: prefer `pip install ansible` over the distro-packaged version — distro packages typically lag several minor releases behind.

**Step 0.2 — Generate the Ansible SSH key pair**
> `ssh-keygen -t ed25519 -f ~/.ssh/k8s_ansible` — or let install-tools.sh prompt for this.
> The public key goes into every VM via cloud-init (Terraform `initialization` block).
> The private key gets stored as `ANSIBLE_SSH_PRIVATE_KEY` in GitHub Actions Secrets.

---

## Phase 1: Proxmox Preparation

**Step 1.1 — Create a dedicated Proxmox user for Terraform**
> Do not use root. Create `terraform@pve` with minimum required roles:
> VM.Allocate, VM.Clone, VM.Config.*, Datastore.AllocateSpace, SDN.Use.
> Docs: https://pve.proxmox.com/wiki/User_Management

**Step 1.2 — Create a Proxmox API token for terraform@pve**
> Proxmox UI → Datacenter → Permissions → API Tokens → Add.
> Store the Token ID and Secret immediately — the secret is only shown once.
> Docs: https://pve.proxmox.com/wiki/Proxmox_VE_API#API_Tokens

**Step 1.3 — Create a dedicated Proxmox user and API token for Packer**
> Do not reuse `terraform@pve` — Packer needs a different permission set.
> Create `packer@pve` with these roles:
> VM.Allocate, VM.Config.*, VM.PowerMgmt, VM.Audit, VM.GuestAgent.Audit, VM.GuestAgent.Unrestricted, Datastore.AllocateSpace, Datastore.Allocate, Datastore.AllocateTemplate, Datastore.Audit, SDN.Use.
> `VM.GuestAgent.Audit` and `VM.GuestAgent.Unrestricted` are **critical** — without them, the Proxmox API returns 403 when Packer queries `/nodes/{node}/qemu/{vmid}/agent/network-get-interfaces` to discover the VM's IP address. Packer silently retries until `ssh_timeout` expires with no useful error. Symptoms: VM boots, installs, SSH is reachable manually, but Packer never connects.
> `Datastore.Allocate` and `Datastore.AllocateTemplate` are required for Packer to upload the cidata ISO to Proxmox storage.
> `SDN.Use` is required when vmbr0 is managed by the Proxmox SDN zone (zone named "localnetwork" by default) — without it, VM network creation fails.
> `VM.PowerMgmt` is required to start/stop the VM during the build — Terraform also needs this.
> Packer does NOT need VM.Clone — it builds from ISO, not from an existing template.
>
> Then create an API token for `packer@pve` (same UI path as Step 1.2). Store the Token ID and Secret immediately.
> Export as environment variables before running `packer build`:
> `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET` — reference these in the Packer HCL via `var.proxmox_token_id` etc.
> Also store both as GitHub Actions secrets (`PACKER_TOKEN_ID`, `PACKER_TOKEN_SECRET`) for any future CI builds.
> Docs: https://pve.proxmox.com/wiki/User_Management

**Step 1.4 — Understand what you are building before writing any Packer config**
> A Proxmox VM template is a locked, non-bootable VM image that Terraform clones for every k8s node. You do not touch it after creation — Terraform and cloud-init handle all per-VM configuration at clone time.
> Read these two Proxmox docs before writing anything:
> 1. What a VM template is and how it is created from a VM: https://pve.proxmox.com/wiki/VM_Templates_and_Clones
> 2. How Proxmox cloud-init works and why the template must include a cloud-init drive: https://pve.proxmox.com/wiki/Cloud-Init_Support
>
> **Which Packer builder to use — and why**
> Packer has two Proxmox builders:
>
> | Builder | Starting point | When to use |
> |---|---|---|
> | `proxmox-iso` | A raw OS ISO | First-time setup — no template exists yet, so you build from scratch |
> | `proxmox-clone` | An existing Proxmox VM template | You already have a base template and want to layer changes on top of it |
>
> Use `proxmox-iso` for this step. `proxmox-clone` has nothing to clone until this step produces a template.
>
> **What `proxmox-iso` does end-to-end:**
> 1. Authenticates to the Proxmox API using the token from Step 1.3
> 2. Uploads or references the OS ISO on Proxmox storage
> 3. Creates a VM and boots it from the ISO
> 4. Sends keystrokes to the VM console (boot_command) to inject `autoinstall` into the kernel cmdline and trigger unattended install; the autoinstall config is read from a cidata CD-ROM attached to the VM (Ubuntu 24.04 uses autoinstall/subiquity — not the legacy preseed method)
> 5. Ubuntu installer reads `user-data` from the cidata ISO and installs the OS without human input
> 6. Packer SSHes into the finished VM and runs provisioner shell commands (install packages, configure OS)
> 7. Converts the VM to a Proxmox template and shuts it down
>
> Read the full `proxmox-iso` builder reference for all required and optional config fields:
> https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/iso
>
>
> **Choosing a base distro for your VMs:**
> The Packer template defines what OS all your k8s VMs (control plane and workers) run. Pick one and be consistent — your Ansible roles must match.
>
> | Distro | Notes |
> |---|---|
> | Ubuntu 24.04 LTS | Most blog/tutorial coverage for kubeadm; containerd from Docker's apt repo; Kubernetes apt repo at `pkgs.k8s.io` |
> | Debian 12 | Very similar to Ubuntu; same apt repos work; slightly smaller base image |
> | Fedora 40 / Rocky Linux 9 | dnf-based; HashiCorp and Kubernetes both maintain official dnf repos; `containerd` available from Docker's dnf repo |
> | Arch Linux | Smallest footprint; `kubeadm`, `kubelet`, `kubectl`, `containerd` all in official repos (no extra repo setup needed); rolling release means versions advance without you pinning them |
>
> **Ansible roles must reflect your choice.** Sections 6.2–6.4 below show where to branch by OS family. Ubuntu/Debian are the most documented choice for homelab kubeadm setups but any of the above works.

**Step 1.4a — Understand the three files you need to write**
> The Packer build for Ubuntu 24.04 requires exactly three files. Understanding what each does before writing any of them will prevent confusion:
>
> **File 1: `packer/ubuntu-2404.pkr.hcl`**
> The main Packer config. Contains four blocks in order:
> - `packer {}` — declares the required proxmox plugin and its version. Packer downloads this when you run `packer init`.
> - `variable {}` — one block per variable. Declares what inputs the build accepts (Proxmox URL, token, node name, disk size, etc.). No sensitive values should have defaults — leave them empty so Packer errors if the env var isn't set.
> - `source "proxmox-iso" {}` — the builder config. Describes the VM hardware, ISO location, network, disk, boot command, and SSH communicator settings.
> - `build {}` — ties the source to provisioners. This is where you run shell commands on the VM after install (package installs, OS hardening).
>
> Note: the builder type is `proxmox-iso`, not `proxmox` — the old `proxmox` builder name is deprecated and will produce a warning.
>
> **File 2: `packer/http/user-data`**
> The Ubuntu autoinstall config. This is a YAML file (not HCL) that the Ubuntu 24.04 installer fetches over HTTP from Packer's built-in HTTP server during the boot process. It replaces the old preseed approach used in Ubuntu 20.04 and earlier.
> It defines: locale, keyboard, network (DHCP during install), storage layout, and crucially — the user account that gets created on the VM.
> The username and password you define here must match `ssh_username` and `ssh_password` in your `.pkr.hcl`, because Packer uses those credentials to SSH in after install and run the provisioner.
> This is a template-only credential — it exists only so Packer can connect. Terraform/cloud-init replaces user config on each cloned VM at deploy time.
> Ubuntu autoinstall reference: https://ubuntu.com/server/docs/install/autoinstall-reference
> Ubuntu autoinstall schema (full field list): https://ubuntu.com/server/docs/install/autoinstall-schema
>
> **File 3: `packer/http/meta-data`**
> An empty file. Ubuntu's cloud-init/autoinstall requires both `user-data` and `meta-data` to be present at the same URL path, even if `meta-data` contains nothing. Packer serves both files from its HTTP server. If this file is missing the installer will stall waiting for it.
>
> **Summary of the relationship:**
> ```
> .pkr.hcl boot_command → tells Ubuntu installer: "fetch autoinstall config from http://<packer-ip>:<port>/"
> Ubuntu installer → fetches http/user-data (installs OS using those settings, creates the user)
> Ubuntu installer → fetches http/meta-data (must exist, can be empty)
> Packer SSH communicator → connects using ssh_username/ssh_password (must match what user-data created)
> build {} provisioner → runs shell commands on the now-running VM
> Packer → converts VM to template
> ```
>
> **File structure in your repo:**
> ```
> packer/
>   ubuntu-2404.pkr.hcl
>   http/
>     user-data
>     meta-data
> ```
>
> Good community examples of this exact structure for Proxmox + Ubuntu 24.04:
> - https://github.com/ChristianLempa/boilerplates/tree/main/packer/proxmox (Christian Lempa — well-maintained homelab reference)
> - Search GitHub for `packer proxmox ubuntu 24.04` filtered by recently updated — there are many solid examples and this will surface ones that are current rather than relying on a pinned URL
> These show the complete three-file structure with real `user-data` examples. Use them as reference, not copy-paste — your storage pool names, network bridge, and variable names will differ.

**Step 1.4b — Authentication: API token vs username/password**
> The community examples you find online (including the rkoosaar repo) often use `username` + `password` fields. Your setup uses API token auth (Step 1.3), which uses different field names in the HCL:
>
> | Auth method | Fields in .pkr.hcl |
> |---|---|
> | Username/password (old) | `username`, `password` |
> | API token (your setup) | `username` (set to token ID format), `token` |
>
> For API token auth, `username` takes the full token ID in the format `packer@pve!tokenname` and `token` takes the secret value.
> Set both via environment variables (`PKR_VAR_proxmox_token_id`, `PKR_VAR_proxmox_token_secret`) — never hardcode in the HCL.
> Mark `proxmox_token_secret` with `sensitive = true` in its variable block so Packer redacts it from build output.

**Step 1.4c — The boot_command field and what it actually does**
> `boot_command` is a list of keystrokes Packer sends to the VM's VNC console immediately after it boots from the ISO. It is the bridge between "VM boots from ISO" and "Ubuntu installer fetches your user-data".
>
> For Ubuntu 24.04 server, the boot screen uses GRUB. The sequence is:
> 1. Wait for GRUB to appear (`<wait>` entries give it time)
> 2. Press `e` to open the selected boot entry for editing
> 3. Navigate to the end of the `linux` kernel line
> 4. Append `autoinstall ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/` to the kernel parameters
> 5. Press `F10` or `ctrl+x` to boot with the modified parameters
>
> `{{ .HTTPIP }}` and `{{ .HTTPPort }}` are Packer template variables resolved at build time to the IP and port of Packer's built-in HTTP server running on your machine.
>
> `ds=nocloud-net;s=http://...` tells Ubuntu's cloud-init datasource where to fetch `user-data` and `meta-data`.
>
> The exact boot_command for Ubuntu 24.04 differs from 20.04 — use a 24.04-specific example as reference rather than adapting a 20.04 one. The rkoosaar repo targets 20.04; its boot_command will not work without modification.
> Search GitHub for `packer proxmox ubuntu 24.04` to find current examples with the correct boot_command sequence.

**Step 1.4d — What the provisioner block does and what to put in it**
> After the OS installs and Packer SSHes in, the `build {}` block runs provisioner commands on the live VM before converting it to a template. This is where you bake k8s prerequisites into the image so Terraform doesn't have to install them every time it clones a new node.
>
> What to install/configure in the provisioner for a k8s node template:
> - `qemu-guest-agent` — required for Proxmox to report VM IP addresses and for clean shutdown signals
> - Disable swap — k8s requires swap to be off; do it in the template so it's always correct
> - Load kernel modules: `overlay`, `br_netfilter` — required by containerd and the k8s networking stack
> - Set sysctl params: `net.bridge.bridge-nf-call-iptables=1`, `net.ipv4.ip_forward=1` — required for pod networking
> - `apt-get update && apt-get upgrade -y` — ensure the template starts with current packages
> - Optionally: install `containerd` — saves time at node deploy; version-pin it to match what your Ansible roles expect
>
> Do NOT join the cluster or set a hostname in the provisioner — those are per-VM concerns handled by Terraform cloud-init at clone time. The template should be generic.
>
> After provisioner runs, Packer sets `template_description`, converts the VM to a template, and disconnects. The VM is now locked in Proxmox and cannot be booted directly — only cloned.

**Step 1.5 — Run Packer to build the template**
> Before running, ensure your storage pool name in the HCL matches what actually exists on that Proxmox node. Check in the Proxmox UI under Datacenter → Storage. Common names are `local-lvm`, `local`, or a custom name you set up. Using a wrong storage pool name is the most common first-run failure.
>
> Set env vars from the `packer@pve` token created in Step 1.3:
> ```
> export PKR_VAR_proxmox_token_id="packer@pve!yourtoken"
> export PKR_VAR_proxmox_token_secret="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
> export PKR_VAR_proxmox_node="pve1"
> ```
>
> Then run:
> `packer init packer/` — downloads the proxmox plugin declared in `required_plugins`. Only needed once per machine.
> `packer validate packer/ubuntu-2404.pkr.hcl` — checks HCL syntax and variable references without running a build. Run this first.
> `packer build packer/ubuntu-2404.pkr.hcl` — performs the full build on the node specified by `PKR_VAR_proxmox_node`.
>
> **Build failures and where to look:**
> - Packer output streams to stdout in real time. If it stalls at "Waiting for SSH", the install is either still running (normal — can take 5–10 min) or the boot_command didn't trigger autoinstall correctly.
> - Open the Proxmox UI, find the VM Packer created (named whatever `vm_name` is set to), and open its Console tab. You can watch the install live.
> - If the console shows the Ubuntu installer menu waiting for input, the boot_command didn't execute correctly.
> - If the console shows install progress, Packer is working — just waiting.
>
> **Running on all 4 nodes (no shared storage):**
> Because your Proxmox nodes don't share storage, each node needs its own local copy of the template. Run Packer once per node, changing only the target node each time:
> ```
> PKR_VAR_proxmox_node=pve1 packer build packer/ubuntu-2404.pkr.hcl
> PKR_VAR_proxmox_node=pve2 packer build packer/ubuntu-2404.pkr.hcl
> PKR_VAR_proxmox_node=pve3 packer build packer/ubuntu-2404.pkr.hcl
> PKR_VAR_proxmox_node=pve4 packer build packer/ubuntu-2404.pkr.hcl
> ```
> Run them sequentially, not in parallel — each build creates a VM with the same `vm_id` (e.g. 9000) and the same name on its respective node, which is fine since they are on separate nodes. The resulting template will have the same name on all 4 nodes, which is what Terraform expects when it clones to a specific node.
>
> If the template ever needs rebuilding (OS updates, new packages): delete the existing template from each Proxmox node via the UI, then re-run all 4 builds.
>
> `proxmox-clone` builder reference (for future use, if you later need to layer on top of this template): https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/clone

**Step 1.6 — Plan and reserve IP ranges**
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

**Step 1.7 — Verify Proxmox API access from your developer machine**
> Use curl to call `GET /api2/json/nodes` with the `terraform@pve` API token from Step 1.2.
> A successful JSON response confirms auth before any Terraform is written.
> API reference: https://pve.proxmox.com/pve-docs/api-viewer/

---

## Phase 2: OpenTofu State Backend (MinIO S3)

> OpenTofu state is stored on the local MinIO VM (already deployed in Phase 11.0 for Velero). This eliminates any dependency on a third-party service — state never leaves your LAN.
> OpenTofu's `s3` backend is a protocol, not a service — it works with any S3-compatible endpoint including MinIO.

**Step 2.1 — Create the `tfstate` bucket in MinIO**
> MinIO UI or CLI: `mc mb minio/tfstate`
> This bucket already exists if you followed Step 11.0 — just confirm it is present before continuing.

**Step 2.2 — Configure the S3 backend in `terraform/versions.tf`**
> ```hcl
> terraform {
>   backend "s3" {
>     bucket                      = "tfstate"
>     key                         = "k8s-proxmox/terraform.tfstate"
>     region                      = "us-east-1"        # required by the S3 protocol; MinIO ignores it
>     endpoint                    = "http://192.168.1.60:9000"
>     access_key                  = var.minio_access_key
>     secret_key                  = var.minio_secret_key
>     skip_credentials_validation = true
>     skip_metadata_api_check     = true
>     skip_region_validation      = true
>     force_path_style            = true
>     use_lockfile                = true               # OpenTofu 1.8+ native S3 locking — no DynamoDB needed
>   }
> }
> ```
> `use_lockfile = true` writes a `.tflock` file alongside state to prevent concurrent applies — no external lock service required.
> Docs: https://opentofu.org/docs/language/settings/backends/s3/

**Step 2.3 — Initialise the backend from your developer machine**
> `tofu init` — OpenTofu connects to MinIO, creates the state file in the `tfstate` bucket, and confirms the lock mechanism works.
> MinIO must be reachable from your developer machine — if you are not on the LAN, use a VPN or SSH tunnel to `192.168.1.60:9000` first.

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
> The playbook installs: OpenTofu (pinned version via tofuenv), Ansible, kubectl, Helm, argocd CLI, velero CLI, bao CLI, git, curl, jq, Python3.
> This is the same tool set as `scripts/install-tools.sh` — consider reusing that script as the playbook's shell task.
> The runner VM's OS will be whatever distro your Packer template produced (Step 1.3). Write the runner setup playbook to use `ansible_os_family` or `ansible_pkg_mgr` facts to branch package install tasks accordingly — e.g. `apt` tasks under `when: ansible_os_family == "Debian"`, `dnf` tasks under `when: ansible_os_family == "RedHat"`, `pacman` tasks under `when: ansible_os_family == "Archlinux"`.
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
> Declare pinned OpenTofu version (managed via `tofuenv` — see `.terraform-version` file), `bpg/proxmox` provider version, and the MinIO S3 backend block (configured in Phase 2). Use `required_version` with an OpenTofu version string.
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
> The deploy-worker and remove-worker workflows both use `tofu show -json` to read current state rather than relying on output files, so state is always authoritative.

**Step 5.6 — Create a CI workflow for `terraform plan` on pull requests**
> File: `.github/workflows/terraform-plan.yml`
> Trigger: pull request that modifies any file under `terraform/`
> Steps: `tofu init` → `tofu plan` → post the plan output as a PR comment
> This is for visibility and review — it does not block the merge.
> The comment lets you see exactly what Terraform will change before it runs.
> Reference: https://developer.hashicorp.com/terraform/tutorials/automation/github-actions
>
> **After writing this workflow and pushing it, return to Step 4.5 and complete the branch protection setup:**
> The `terraform-plan` status check name only appears in the GitHub branch protection UI after the workflow has run at least once on a PR. Open a test PR against `main` touching any file in `terraform/`, let the workflow run, then go to Settings → Branches → edit the `main` protection rule and add `terraform-plan` as a required status check.

---

## Phase 6: Ansible Role Definitions

> Write all Ansible roles in this phase. Nothing is run yet — the bootstrap workflow executes them.

**Step 6.1 — Write `ansible/group_vars/` variable files**
> Three files, all committed to Git:
> - `all.yml` — shared variables for every node: Kubernetes version (e.g. `1.30`), pod CIDR (`192.168.0.0/16`), SSH user (`ubuntu`), SSH key path, LAN gateway, DNS server
> - `controlplane.yml` — control plane–specific variables: `keepalived_vip` (the VIP address from Step 1.5), `kubeadm_cert_key` (populated at runtime by bootstrap workflow), primary CP node name (`controlplane-pve1`)
> - `workers.yml` — worker-specific variables: any worker-only settings (e.g. kubelet resource reservations)

**Step 6.2 — Write the `common` role**
> Targets all nodes. Disables swap, loads `overlay` + `br_netfilter` kernel modules, sets required sysctl params, installs OS dependencies.
> Use Ansible's `package` module for packages that have the same name across distros (e.g. `curl`, `ca-certificates`). For distro-specific package names or repos, branch by `ansible_os_family`:
> ```yaml
> - name: Install prerequisites
>   package:
>     name: [curl, ca-certificates, gnupg]
>     state: present
>
> - name: Install apt transport (Debian/Ubuntu only)
>   apt:
>     name: apt-transport-https
>     state: present
>   when: ansible_os_family == "Debian"
> ```
> Reference: https://kubernetes.io/docs/setup/production-environment/container-runtimes/

**Step 6.3 — Write the `containerd` role**
> Installs containerd, generates default config, sets `SystemdCgroup = true`, restarts the service. The install path differs by distro:
>
> | Distro family | Install method |
> |---|---|
> | Ubuntu / Debian | Docker's apt repo (`download.docker.com/linux/ubuntu` or `/debian`); package name `containerd.io`. Reference: https://docs.docker.com/engine/install/ubuntu/ |
> | Fedora / RHEL / Rocky | Docker's dnf repo (`download.docker.com/linux/fedora` or `/rhel`); package name `containerd.io`. Reference: https://docs.docker.com/engine/install/fedora/ |
> | Arch / Manjaro | Official repo — `pacman -S containerd`; no extra repo setup needed. |
>
> All distros: after install, run `containerd config default > /etc/containerd/config.toml`, then set `SystemdCgroup = true` in that file (the `sed` or `lineinfile` approach works on all distros since the config format is identical regardless of how containerd was installed).
> Branch the install tasks by `ansible_os_family` — the config generation and service restart steps are distro-agnostic and can run unconditionally.

**Step 6.4 — Write the `kubeadm` role**
> Installs `kubeadm`, `kubelet`, `kubectl` at a pinned version, then prevents automatic upgrades. How to do this depends on the distro:
>
> | Distro family | Repo setup | Version pin |
> |---|---|---|
> | Ubuntu / Debian | Kubernetes apt repo at `pkgs.k8s.io`; package names `kubeadm`, `kubelet`, `kubectl` | `apt-mark hold kubeadm kubelet kubectl` |
> | Fedora / RHEL / Rocky | Kubernetes dnf repo at `pkgs.k8s.io`; package names `kubeadm`, `kubelet`, `kubectl` | `dnf versionlock add kubeadm kubelet kubectl` (requires `python3-dnf-plugin-versionlock`) |
> | Arch / Manjaro | No extra repo needed — packages are in the official `extra` repo or AUR; package names `kubeadm`, `kubelet`, `kubectl` | Add to `/etc/pacman.conf`: `IgnorePkg = kubeadm kubelet kubectl` |
>
> All distros: enable and start the `kubelet` service after install. kubeadm will manage the kubelet configuration — the version pinning is the critical step to prevent automatic upgrades breaking the cluster.
> Reference: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
> Kubernetes package repos (apt + dnf): https://pkgs.k8s.io

**Step 6.5 — Write the `keepalived` role**
> Installs and configures keepalived on all three CP VMs to provide the VIP.
> The primary CP node (pve1) holds the VIP by default; pve2 and pve3 take over if pve1 fails.
> The VIP address comes from the Ansible variable set in group_vars/controlplane.yml.
> The package name is `keepalived` on all major distros — install via the appropriate package manager. The `/etc/keepalived/keepalived.conf` config format is identical across distros.
> Reference: https://keepalived.readthedocs.io/en/latest/configuration_synopsis.html

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
> Configure **two** `BackupStorageLocation` resources — this is what gives you 3-2-1:
> - `local` (default): MinIO on Proxmox (`http://192.168.1.60:9000`) — fast local restore, same site
> - `offsite`: Backblaze B2 — S3-compatible endpoint (`https://s3.us-west-004.backblazeb2.com`), different physical location
>
> Both locations receive every backup. Velero supports multiple storage locations natively — set `default: true` on the MinIO location so restores default to local (faster), with B2 available as the DR target.
> A `Schedule` CRD triggers a daily full backup at 02:00 with 7-day retention, writing to both locations.
> A separate `CronJob` on each control plane node runs `etcdctl snapshot save` nightly and uploads to both MinIO (`etcd/` prefix) and Backblaze B2 (`etcd/` prefix) via `rclone` or `aws s3 cp --endpoint-url`.
>
> This satisfies 3-2-1: live cluster (copy 1) + local MinIO (copy 2, local) + Backblaze B2 (copy 3, offsite, different medium).
> **DR recovery sequence**: Rebuild infra (Packer → Terraform → Ansible → kubeadm) → bootstrap ArgoCD → `velero restore --from-backup <name> --storage-location offsite` → verify.
> No manual backup triggers — everything is GitOps-managed and runs automatically once ArgoCD syncs it.
> Velero multiple storage locations: https://velero.io/docs/latest/api-types/backupstoragelocation/
> Backblaze B2 S3-compatible docs: https://www.backblaze.com/docs/cloud-storage-s3-compatible-api
> Reference: https://velero.io/docs/latest/basic-install/
> Velero Helm chart: https://vmware-tanzu.github.io/helm-charts/

**Step 7.8 — Write prometheus-pve-exporter manifest in `k8s/monitoring/`**
> A `Deployment` running the `prometheus-pve-exporter` container, pointed at the Proxmox API URL with the API token stored in a k8s Secret.
> A `Service` and `ServiceMonitor` CRD so Prometheus (via kube-prometheus-stack) automatically discovers and scrapes the exporter.
> This adds Proxmox-layer metrics to Grafana: per-Proxmox-node CPU/RAM, VM power states, storage pool utilisation.
> Cross-referencing these with the placement algorithm in deploy-worker lets you see if a Proxmox host is saturated before committing to placing a VM there.
> Reference: https://github.com/prometheus-pve/prometheus-pve-exporter

---

## Phase 7d: OpenBao — Secrets Management

> OpenBao is the open-source Vault fork (Linux Foundation, MPL-2.0). It runs as a standalone Proxmox VM outside the k8s cluster and stores all project secrets. External Secrets Operator (ESO), deployed by ArgoCD, syncs secrets from OpenBao into k8s Secrets inside the cluster.
> This VM must be provisioned before the bootstrap workflow runs (same as MinIO).

**Step 7d.1 — Provision the OpenBao VM on Proxmox**
> Clone the Packer template to a new VM: 2 CPU, 2 GB RAM, 20 GB disk.
> Assign a static IP outside the k8s IP ranges from Step 1.5 (e.g. `192.168.1.61`).
> SSH in and install OpenBao:
> ```
> curl -fsSL https://apt.releases.opentofu.org/gpg | sudo gpg --dearmor -o /usr/share/keyrings/opentofu.gpg
> # Use OpenBao release from https://openbao.org/docs/install/
> ```
> Reference: https://openbao.org/docs/install/

**Step 7d.2 — Initialise and unseal OpenBao**
> Run `bao operator init` — this outputs 5 unseal keys and a root token. Store all of them in a secure location (KeePassXC or similar) immediately — they cannot be recovered.
> Run `bao operator unseal` three times with three different unseal keys to unseal.
> OpenBao must be manually unsealed after every reboot — this is expected for a homelab.
> Docs: https://openbao.org/docs/concepts/seal/

**Step 7d.3 — Enable kv-v2 secrets engine and load project secrets**
> ```
> export BAO_ADDR=http://192.168.1.61:8200
> export BAO_TOKEN=<root-token>
> bao secrets enable -path=secret kv-v2
> ```
> Load all project secrets into OpenBao:
> ```
> bao kv put secret/proxmox api_token_id=<value> api_token_secret=<value>
> bao kv put secret/github pat=<value>
> bao kv put secret/discord webhook_url=<value>
> bao kv put secret/minio access_key=<value> secret_key=<value>
> bao kv put secret/backblaze access_key=<keyID> secret_key=<applicationKey>
> ```
> These replace the equivalent GitHub Secrets entries — GitHub Secrets only retains the credentials needed by workflows before the cluster exists (PROXMOX_API_TOKEN_ID/SECRET, ANSIBLE_SSH_PRIVATE_KEY, OPENBAO_ADDR, OPENBAO_TOKEN).

**Step 7d.4 — Enable Kubernetes auth method (configured after bootstrap)**
> The k8s auth method lets pods authenticate to OpenBao using their ServiceAccount token — no static credentials needed inside the cluster.
> This step is completed after the cluster exists (Phase 9). Add it as a follow-up in the bootstrap workflow or run manually post-bootstrap:
> ```
> bao auth enable kubernetes
> bao write auth/kubernetes/config \
>   kubernetes_host=https://<VIP>:6443 \
>   kubernetes_ca_cert=@/etc/kubernetes/pki/ca.crt
> ```
> Then create a policy and role for ESO:
> ```
> bao policy write eso-reader - <<EOF
> path "secret/data/*" { capabilities = ["read"] }
> EOF
> bao write auth/kubernetes/role/eso \
>   bound_service_account_names=external-secrets \
>   bound_service_account_namespaces=external-secrets \
>   policies=eso-reader ttl=1h
> ```
> Docs: https://openbao.org/docs/auth/kubernetes/

**Step 7d.5 — Write ESO manifests for ArgoCD**
> File: `k8s/secrets/` — add to ArgoCD App-of-Apps.
>
> `k8s/secrets/clustersecretstore.yaml`:
> ```yaml
> apiVersion: external-secrets.io/v1beta1
> kind: ClusterSecretStore
> metadata:
>   name: openbao-backend
> spec:
>   provider:
>     vault:
>       server: "http://192.168.1.61:8200"
>       path: "secret"
>       version: "v2"
>       auth:
>         kubernetes:
>           mountPath: "kubernetes"
>           role: "eso"
> ```
>
> `k8s/secrets/discord-webhook.yaml` (example ExternalSecret):
> ```yaml
> apiVersion: external-secrets.io/v1beta1
> kind: ExternalSecret
> metadata:
>   name: discord-webhook
>   namespace: monitoring
> spec:
>   refreshInterval: 1h
>   secretStoreRef:
>     name: openbao-backend
>     kind: ClusterSecretStore
>   target:
>     name: discord-webhook-secret
>   data:
>     - secretKey: url
>       remoteRef:
>         key: discord
>         property: webhook_url
> ```
> Add equivalent ExternalSecrets for MinIO credentials (namespace: velero) and GitHub PAT (namespace: monitoring, for webhook adapter).
> ESO Helm chart docs: https://external-secrets.io/latest/introduction/getting-started/

**Step 7d.6 — Add ESO to ArgoCD App-of-Apps**
> Add `k8s/secrets/` as an ArgoCD Application in `argocd/apps/secrets.yaml`.
> ESO itself is installed via its Helm chart — add a HelmRelease in `k8s/secrets/eso-helmrelease.yaml` pointing to the `external-secrets` Helm repo.
> ArgoCD will deploy ESO and all ExternalSecret resources when it first syncs after bootstrap.

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
> 3. `tofu init` + `tofu apply` — creates all 3 control plane VMs (pve1, pve2, pve3) + first worker VM on the best-capacity node (all with static IPs from cloud-init)
> 4. Wait for VMs to finish cloud-init and become SSH-reachable (poll with ssh until ready)
> 5. Generate Ansible inventory from `tofu output -json` using `jq` → writes `ansible/inventory/hosts.ini` with `[controlplane_primary]`, `[controlplane_secondary]`, and `[workers]` groups
> 6. Run Ansible roles in order against the inventory:
>    - `common` + `containerd` + `kubeadm` → all nodes
>    - `keepalived` → all 3 CP nodes (VIP comes up before kubeadm runs)
>    - `controlplane` → primary CP node (pve1) — `kubeadm init --control-plane-endpoint <VIP>:6443 --upload-certs --pod-network-cidr=192.168.0.0/16`
>    - `controlplane-join` → secondary CP nodes (pve2, pve3) sequentially — `kubeadm join --control-plane`
>    - `worker` → first worker node — `kubeadm join <VIP>:6443`
> 7. Apply Calico CNI manifests via kubectl (pod CIDR must match `192.168.0.0/16`)
> 8. Wait for all nodes `Ready` (`kubectl get nodes` — poll with timeout)
> 9. Install ArgoCD via `helm install` — this is the only manual Helm install; ArgoCD manages everything after this
> 10. Wait for ArgoCD pods `Ready`
> 11. Connect ArgoCD to the GitHub repo (kubectl apply of an ArgoCD Repository Secret or `argocd repo add`)
> 12. Apply the root App-of-Apps Application — ArgoCD picks up `argocd/apps/` and begins syncing MetalLB, ingress-nginx, monitoring (kube-prometheus-stack + Loki + pve-exporter), and backup (Velero)
> 13. Wait for all ArgoCD applications to reach `Synced/Healthy`
> 14. Retrieve kubeconfig from the primary CP node, base64-encode it, write it to GitHub Secrets via the GitHub API
> 15. Send Discord notification: "✅ Cluster bootstrapped — {worker_count} workers ready, ArgoCD synced"
>
> ArgoCD CLI docs: https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd/
> ArgoCD repo secret: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories

---

## Phase 10: AlertManager Rules and Webhook Adapter

> These are all written as k8s manifests and deployed via ArgoCD from `k8s/monitoring/`.

**Step 10.1 — Write the five PrometheusRule alert definitions**
> `k8s/monitoring/alert-rules.yaml` — a `PrometheusRule` CRD with five rules:
> - `NodeMemoryPressure`: single worker RAM > 75% for 5 minutes → fires `resource-pressure` event (metric=`memory`)
> - `NodeCPUPressure`: single worker CPU > 80% for 5 minutes → fires `resource-pressure` event (metric=`cpu`)
> - `NodeDiskPressure`: single worker root disk > 80% for 5 minutes → fires `resource-pressure` event (metric=`disk`)
> - `NodeUnderutilised`: single worker RAM < 30% **and** CPU < 20% for 15 minutes → fires `scale-in` event
> - `ClusterHighLoad`: ALL workers simultaneously > 75% RAM **or** ALL workers > 80% CPU → fires `scale-out` event
> The `NodeUnderutilised` rule uses a PromQL `and` expression to require both conditions — this prevents removing a node that is RAM-idle but CPU-bound.
> Reference: https://prometheus-operator.dev/docs/user-guides/alerting/

**Step 10.2 — Write and deploy the webhook adapter**
> `k8s/monitoring/webhook-adapter.yaml` — a `Deployment` + `Service` in the `monitoring` namespace.
> The adapter translates AlertManager's webhook payload into GitHub's `repository_dispatch` format, injecting the node label from the alert into `client_payload.node` and the alert name into `client_payload.metric` (mapped: NodeMemoryPressure→memory, NodeCPUPressure→cpu, NodeDiskPressure→disk).
> Store the GitHub PAT as a k8s Secret in the same namespace — the adapter reads it from there.
> Reference: https://github.com/prometheus-community/alertmanager-webhook-adapter

**Step 10.3 — Write AlertManager routing config**
> Update the kube-prometheus-stack Helm values (or write an `AlertmanagerConfig` CRD) to route:
> - `NodeMemoryPressure`, `NodeCPUPressure`, `NodeDiskPressure` → webhook adapter → `resource-pressure` dispatch (with metric field set by adapter)
> - `NodeUnderutilised` → webhook adapter → `scale-in` dispatch
> - `ClusterHighLoad` → webhook adapter → `scale-out` dispatch
> - `NodeNotReady`, `PodCrashLooping`, and other health alerts → AlertManager `discord_config` receiver directly (Path B notifications — bypasses GitHub entirely)
> AlertmanagerConfig CRD: https://prometheus-operator.dev/docs/user-guides/alerting/#using-alertmanagerconfig

**Step 10.4 — Write ArgoCD Notifications Controller config**
> The ArgoCD Notifications Controller is not enabled by default — it requires opt-in.
> Enable it in the ArgoCD Helm values (or as an ArgoCD install argument): `--enable-notification-controller`.
> Write `k8s/monitoring/argocd-notifications-cm.yaml` — a `ConfigMap` in the `argocd` namespace that configures:
>   - A Discord contact point using `DISCORD_WEBHOOK_URL` from a Secret in the `argocd` namespace
>   - Triggers for: `on-sync-failed`, `on-health-degraded`, `on-sync-succeeded`
>   - Subscriptions on all ArgoCD Applications (or annotate individual Applications)
> This implements Path C from PLAN.md Layer 6b — ArgoCD events → Discord independent of GitHub Actions.
> Reference: https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/

**Step 10.5 — Commit all monitoring manifests**
> Committing to Git triggers ArgoCD to sync and apply them automatically — no manual kubectl needed.

---

## Phase 11: GitHub Actions Secrets

**Step 11.0 — Deploy MinIO on Proxmox and configure Backblaze B2 (prerequisites for Velero)**
> Both storage targets must exist before the bootstrap workflow runs — Velero (deployed by ArgoCD in Phase 9 step 12) immediately tries to connect to its configured storage locations.
>
> **MinIO (local — copy 2 of 3):**
> MinIO is not a Kubernetes workload — run it as a standalone VM on Proxmox (outside the k8s cluster) so it remains available during cluster rebuilds.
> 1. Clone the Packer template to create a small Proxmox VM (2 CPU, 4 GB RAM, 100 GB disk)
> 2. Assign a static IP outside the k8s IP ranges (e.g. `192.168.1.60`)
> 3. Install MinIO: https://min.io/docs/minio/linux/index.html
> 4. Create two buckets: `velero` (Velero backups + etcd snapshots) and `tfstate` (OpenTofu state)
> 5. Create a MinIO access key and secret key with read/write access to both buckets
>
> **Backblaze B2 (offsite — copy 3 of 3):**
> 1. Sign up at https://www.backblaze.com/sign-up/cloud-storage — free tier includes 10 GB; beyond that ~$6/TB/month
> 2. Create a bucket named `k8s-velero-offsite` (set to private)
> 3. Create an application key with read/write access to that bucket only — note the `keyID` and `applicationKey`
> 4. B2 S3-compatible endpoint format: `https://s3.<region>.backblazeb2.com` — find your bucket's region in the B2 UI
> 5. Store `keyID` as `B2_ACCESS_KEY` and `applicationKey` as `B2_SECRET_KEY` in OpenBao (`bao kv put secret/backblaze access_key=<keyID> secret_key=<applicationKey>`)

**Step 11.1 — Store all secrets in GitHub Actions**
> GitHub repo → Settings → Secrets and variables → Actions.
> Only the secrets GitHub Actions needs BEFORE the cluster exists go here. All others live in OpenBao and are synced into the cluster by ESO.
> Required secrets:
> - `PROXMOX_API_TOKEN_ID` — Proxmox API token ID
> - `PROXMOX_API_TOKEN_SECRET` — Proxmox API token secret
> - `ANSIBLE_SSH_PRIVATE_KEY` — Ansible SSH private key
> - `GH_DISPATCH_TOKEN` — GitHub PAT with `workflow` scope (for webhook adapter + scaling workflows)
> - `OPENBAO_ADDR` — OpenBao server address (e.g. `http://192.168.1.61:8200`)
> - `OPENBAO_TOKEN` — OpenBao token for bootstrap workflow to read secrets during cluster init
> Note: `KUBECONFIG_B64` is written automatically by the bootstrap workflow (Step 9.1 step 14).
> Discord webhook URL, MinIO credentials, and all other runtime secrets are loaded into OpenBao (Step 7d.3) and synced into k8s Secrets by ESO post-bootstrap.

**Step 11.2 — Confirm MinIO is reachable from the self-hosted runner**
> The runner VM needs network access to MinIO (`http://192.168.1.60:9000`) for every `tofu init/plan/apply` — both are on the LAN so this should work automatically.
> Test from the runner: `curl -s http://192.168.1.60:9000/minio/health/live` — a 200 response confirms MinIO is up and reachable.

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
> 6. `tofu init` + `tofu apply` with new worker added to map
> 7. Generate inventory for new VM IP from `tofu output`
> 8. Run Ansible `site.yml` targeting new VM only
> 9. Poll `kubectl get nodes` until new node is `Ready` (5-minute timeout; on timeout → send Discord failure + fail workflow)
> 10. Send Discord: "✅ Worker {name} joined cluster on {node}"

**Step 12.2 — Write `remove-worker` workflow**
> File: `.github/workflows/remove-worker.yml`
> Trigger: `repository_dispatch` type `scale-in`
> Steps:
> 1. Send Discord: "⏳ Scale-in triggered for {node}"
> 2. Re-query Prometheus API — confirm BOTH RAM < 30% AND CPU < 20% still hold (matching the `NodeUnderutilised` dual condition); if either has recovered → send Discord "ℹ️ Scale-in cancelled — node recovered" → exit cleanly
> 3. Count current workers — if only 1 remains → send Discord "⚠️ Scale-in blocked — last worker" → enter `manual-review` gate
> 4. `kubectl drain {node} --ignore-daemonsets --delete-emptydir-data`
> 5. `kubectl delete node {node}`
> 6. Remove worker entry from workers map, `tofu apply` → VM destroyed on Proxmox
> 7. Verify node absent from `kubectl get nodes`
> 8. Send Discord: "✅ Worker {name} removed — cluster at {remaining} workers"
> Prometheus HTTP API: https://prometheus.io/docs/prometheus/latest/querying/api/

**Step 12.3 — Write `resize-worker` workflow**
> File: `.github/workflows/resize-worker.yml`
> Trigger: `repository_dispatch` type `resource-pressure` (carries `client_payload.metric`: `memory` | `cpu` | `disk`)
> Steps:
> 1. Read `client_payload.node` and `client_payload.metric` from the dispatch payload
> 2. Send Discord: "⏳ Resource pressure ({metric}) on {node} — checking current allocation"
> 3. Read current RAM and CPU cores for target VM from `tofu show -json`
> 4. **Decision gate by metric:**
>    - **metric = memory:**
>      - If current RAM < 16 GB: send Discord "⏳ Vertically scaling {name}: {old}GB RAM → {new}GB"; cordon → drain → tofu apply (+4 GB) → wait for Ready → uncordon → send Discord "✅ Memory resize complete"
>      - If current RAM >= 16 GB: send Discord "ℹ️ {name} at RAM cap (16 GB) — triggering horizontal scale-out"; fire `scale-out` repository_dispatch → exit
>    - **metric = cpu:**
>      - If current cores < 8: send Discord "⏳ Vertically scaling {name}: {old} cores → {new} cores"; cordon → drain → tofu apply (+2 cores) → wait for Ready → uncordon → send Discord "✅ CPU resize complete"
>      - If current cores >= 8: send Discord "ℹ️ {name} at CPU cap (8 cores) — triggering horizontal scale-out"; fire `scale-out` repository_dispatch → exit
>    - **metric = disk:**
>      - Disk pressure always triggers horizontal scale-out (VMs cannot be vertically resized for disk without unmounting); send Discord "ℹ️ Disk pressure on {name} — triggering horizontal scale-out"; fire `scale-out` repository_dispatch → exit
> `tofu show` docs: https://opentofu.org/docs/cli/commands/show/

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

**Step 13.2 — Test resize (memory)**
> Run `stress-ng --vm 1 --vm-bytes 80%` on ONE worker.
> Observe: `NodeMemoryPressure` alert → `resize-worker` workflow (metric=memory) → cordon/drain/resize/rejoin → Discord notifications at each stage.
> Verify the new RAM value in `terraform show`.

**Step 13.3 — Test the 16 GB cap → horizontal trigger**
> Manually update the workers map in Terraform to set one worker to 16 GB, apply.
> Stress that worker. Confirm `resize-worker` detects the RAM cap and triggers `deploy-worker` instead.
> Discord should show both the "cap hit" notification and the subsequent scale-out notification.
> Also test CPU cap: set a worker to 8 cores, run `stress-ng --cpu 8`, confirm same horizontal fallback.

**Step 13.4 — Test scale-in**
> Let workers idle. After 15 minutes, `NodeUnderutilised` fires (RAM < 30% AND CPU < 20%).
> Observe: `remove-worker` workflow → dual metric re-check → drain → destroy → Discord success notification.
> Confirm `terraform show` no longer lists the removed VM.

**Step 13.5 — Test approval gate (capacity full)**
> Temporarily lower `node_capacities.json` to make all nodes appear full.
> Stress the cluster to trigger `ClusterHighLoad`.
> Confirm: Discord shows "🚨 @here at capacity" message with GitHub approval link → workflow pauses at `manual-review` gate → approve on GitHub (or via Discord bot if built) → workflow either proceeds or exits cleanly.
> Reset `node_capacities.json` after testing.

**Step 13.6 — Verify Loki receiving logs**
> Open Grafana → Explore → select the Loki datasource.
> Run the query: `{namespace="monitoring"}` — you should see log streams from Prometheus and AlertManager pods.
> Run `{namespace="argocd"}` — confirm ArgoCD logs appear.
> If no logs appear: check `kubectl get pods -n monitoring` to confirm Promtail DaemonSet pods are all Running on every node.
> Loki datasource must appear in Grafana's datasource list (provisioned via the ConfigMap written in Step 7.6).

**Step 13.7 — Verify Velero backup ran to both storage locations**
> Run `velero backup get` — you should see a backup created within the last 24 hours with status `Completed`.
> Run `velero backup describe <backup-name>` to confirm it backed up resources across all namespaces.
> Confirm both storage locations received the backup:
> - Local: `mc ls minio/velero/` from the MinIO VM — artifacts present
> - Offsite: `velero backup get --storage-location offsite` — shows same backup with `Completed` status
> Check the etcd CronJob: `kubectl get cronjob -n kube-system` should list `etcd-backup`; `kubectl get jobs -n kube-system` should show it ran successfully.
> Verify 3-2-1 compliance: `velero get backup-locations` should list two locations (`local` and `offsite`), both showing `Available` phase.
> If `offsite` location shows `Unavailable`: check B2 credentials are correctly loaded into the Velero `BackupStorageLocation` secret via ESO.
> If `local` backup shows `Failed`: check MinIO credentials are correctly injected into the Velero Helm values and the MinIO `velero` bucket exists.

**Step 13.8 — Verify pve-exporter metrics in Grafana**
> Open Grafana → Explore → select the Prometheus datasource.
> Run the query: `pve_up` — you should see a metric per Proxmox node (pve1, pve2, pve3, pve4) all returning 1.
> Open the Proxmox dashboard (imported in Step 7.8) — verify CPU, memory, and storage panels are populated.
> If no `pve_` metrics appear: check `kubectl get servicemonitor -n monitoring` includes `pve-exporter`; check that the Prometheus scrape config is picking it up via `kubectl logs -n monitoring -l app=pve-exporter`.

---

## Key Resources Reference

| Topic | Resource |
|---|---|
| Proxmox API tokens | https://pve.proxmox.com/wiki/Proxmox_VE_API#API_Tokens |
| Proxmox cloud-init | https://pve.proxmox.com/wiki/Cloud-Init_Support |
| Proxmox list VMs per node | https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu |
| Proxmox VM templates | https://pve.proxmox.com/wiki/VM_Templates_and_Clones |
| Packer proxmox plugin overview | https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox |
| Packer proxmox-iso builder | https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/iso |
| Packer proxmox-clone builder | https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/clone |
| Ubuntu autoinstall (unattended install) | https://ubuntu.com/server/docs/install/autoinstall |
| bpg/proxmox provider | https://registry.terraform.io/providers/bpg/proxmox/latest/docs |
| bpg/proxmox VM data source | https://registry.terraform.io/providers/bpg/proxmox/latest/docs/data-sources/virtual_environment_vms |
| OpenTofu for_each | https://opentofu.org/docs/language/meta-arguments/for_each/ |
| OpenTofu S3 backend (MinIO) | https://opentofu.org/docs/language/settings/backends/s3/ |
| OpenTofu tofu show | https://opentofu.org/docs/cli/commands/show/ |
| Terraform GitHub Actions (workflow reference) | https://developer.hashicorp.com/terraform/tutorials/automation/github-actions |
| GitHub self-hosted runners | https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners |
| GitHub Environments (approval gates) | https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment |
| GitHub repository_dispatch | https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event |
| kubeadm install | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/ |
| kubeadm cluster creation | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/ |
| containerd install | Ubuntu/Debian: https://docs.docker.com/engine/install/ubuntu/ — Fedora: https://docs.docker.com/engine/install/fedora/ — Arch: `pacman -S containerd` |
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
