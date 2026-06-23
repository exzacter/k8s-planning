#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# install-tools.sh — developer machine setup for k8s-planning project
# Supports: Ubuntu/Debian (apt) and macOS (Homebrew)
# Run once per machine; safe to re-run (checks before installing)
# -----------------------------------------------------------------------------

OPENTOFU_VERSION="1.8.0"
KUBECTL_VERSION="v1.31.0"
HELM_VERSION="v3.16.0"
ARGOCD_VERSION="v2.12.0"
VELERO_VERSION="v1.14.0"
OPENBAO_VERSION="2.0.0"
PACKER_VERSION="1.11.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[x]${NC} $1"; exit 1; }
installed() { command -v "$1" &>/dev/null; }

detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
  elif [[ -f /etc/debian_version ]]; then
    OS="debian"
  else
    error "Unsupported OS. This script supports Ubuntu/Debian and macOS only."
  fi
  info "Detected OS: $OS"
}

# -----------------------------------------------------------------------------
# macOS: ensure Homebrew is present
# -----------------------------------------------------------------------------
ensure_brew() {
  if ! installed brew; then
    warn "Homebrew not found — installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
}

# -----------------------------------------------------------------------------
# Base packages
# -----------------------------------------------------------------------------
install_base() {
  info "Installing base packages (git, curl, jq, python3, pip)..."
  if [[ "$OS" == "debian" ]]; then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
      git curl jq python3 python3-pip python3-venv unzip wget gnupg lsb-release ca-certificates
  else
    brew install git curl jq python3
  fi
}

# -----------------------------------------------------------------------------
# GitHub CLI (gh)
# -----------------------------------------------------------------------------
install_gh() {
  if installed gh; then
    info "gh $(gh --version | head -1 | awk '{print $3}') already installed — skipping"
    return
  fi
  info "Installing GitHub CLI (gh)..."
  if [[ "$OS" == "debian" ]]; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
      https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y gh
  else
    brew install gh
  fi
}

# -----------------------------------------------------------------------------
# tofuenv + OpenTofu
# -----------------------------------------------------------------------------
install_opentofu() {
  if installed tofu; then
    info "OpenTofu $(tofu version | head -1) already installed — skipping"
    return
  fi
  info "Installing tofuenv + OpenTofu ${OPENTOFU_VERSION}..."
  if [[ "$OS" == "debian" ]]; then
    if [[ ! -d "$HOME/.tofuenv" ]]; then
      git clone --depth=1 https://github.com/tofuutils/tofuenv.git "$HOME/.tofuenv"
    fi
    export PATH="$HOME/.tofuenv/bin:$PATH"
    # Add to shell profile if not already present
    for profile in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [[ -f "$profile" ]] && grep -q 'tofuenv' "$profile" \
        || echo 'export PATH="$HOME/.tofuenv/bin:$PATH"' >> "$profile"
    done
    tofuenv install "$OPENTOFU_VERSION"
    tofuenv use "$OPENTOFU_VERSION"
  else
    brew install tofuenv
    tofuenv install "$OPENTOFU_VERSION"
    tofuenv use "$OPENTOFU_VERSION"
  fi
}

# -----------------------------------------------------------------------------
# Packer
# -----------------------------------------------------------------------------
install_packer() {
  if installed packer; then
    info "Packer $(packer version | head -1) already installed — skipping"
    return
  fi
  info "Installing Packer ${PACKER_VERSION}..."
  if [[ "$OS" == "debian" ]]; then
    ARCH=$(dpkg --print-architecture)
    PACKER_URL="https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_${ARCH}.zip"
    curl -fsSL "$PACKER_URL" -o /tmp/packer.zip
    sudo unzip -o /tmp/packer.zip -d /usr/local/bin/
    sudo chmod +x /usr/local/bin/packer
    rm /tmp/packer.zip
  else
    brew install hashicorp/tap/packer
  fi
}

# -----------------------------------------------------------------------------
# kubectl
# -----------------------------------------------------------------------------
install_kubectl() {
  if installed kubectl; then
    info "kubectl $(kubectl version --client --short 2>/dev/null | awk '{print $3}') already installed — skipping"
    return
  fi
  info "Installing kubectl ${KUBECTL_VERSION}..."
  if [[ "$OS" == "debian" ]]; then
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /tmp/kubectl
    sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm /tmp/kubectl
  else
    brew install kubectl
  fi
}

# -----------------------------------------------------------------------------
# Helm
# -----------------------------------------------------------------------------
install_helm() {
  if installed helm; then
    info "Helm $(helm version --short) already installed — skipping"
    return
  fi
  info "Installing Helm ${HELM_VERSION}..."
  if [[ "$OS" == "debian" ]]; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    brew install helm
  fi
}

# -----------------------------------------------------------------------------
# ArgoCD CLI
# -----------------------------------------------------------------------------
install_argocd() {
  if installed argocd; then
    info "argocd $(argocd version --client --short 2>/dev/null | head -1) already installed — skipping"
    return
  fi
  info "Installing ArgoCD CLI ${ARGOCD_VERSION}..."
  if [[ "$OS" == "debian" ]]; then
    curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64" \
      -o /tmp/argocd
    sudo install -m 0755 /tmp/argocd /usr/local/bin/argocd
    rm /tmp/argocd
  else
    brew install argocd
  fi
}

# -----------------------------------------------------------------------------
# Velero CLI
# -----------------------------------------------------------------------------
install_velero() {
  if installed velero; then
    info "velero $(velero version --client-only 2>/dev/null | head -1) already installed — skipping"
    return
  fi
  info "Installing Velero CLI ${VELERO_VERSION}..."
  VELERO_TARBALL="velero-${VELERO_VERSION}-linux-amd64.tar.gz"
  if [[ "$OS" == "macos" ]]; then
    VELERO_TARBALL="velero-${VELERO_VERSION}-darwin-amd64.tar.gz"
  fi
  curl -fsSL "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/${VELERO_TARBALL}" \
    -o /tmp/velero.tar.gz
  tar -xzf /tmp/velero.tar.gz -C /tmp/
  sudo install -m 0755 "/tmp/velero-${VELERO_VERSION}-linux-amd64/velero" /usr/local/bin/velero 2>/dev/null \
    || sudo install -m 0755 "/tmp/velero-${VELERO_VERSION}-darwin-amd64/velero" /usr/local/bin/velero
  rm -rf /tmp/velero.tar.gz /tmp/velero-*/
}

# -----------------------------------------------------------------------------
# OpenBao CLI (bao)
# -----------------------------------------------------------------------------
install_openbao() {
  if installed bao; then
    info "bao $(bao version 2>/dev/null | head -1) already installed — skipping"
    return
  fi
  info "Installing OpenBao CLI (bao) ${OPENBAO_VERSION}..."
  if [[ "$OS" == "debian" ]]; then
    BAO_URL="https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/bao_${OPENBAO_VERSION}_linux_amd64.deb"
    curl -fsSL "$BAO_URL" -o /tmp/bao.deb
    sudo dpkg -i /tmp/bao.deb
    rm /tmp/bao.deb
  else
    BAO_URL="https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/bao_${OPENBAO_VERSION}_darwin_amd64.zip"
    curl -fsSL "$BAO_URL" -o /tmp/bao.zip
    unzip -o /tmp/bao.zip bao -d /tmp/
    sudo install -m 0755 /tmp/bao /usr/local/bin/bao
    rm /tmp/bao.zip /tmp/bao
  fi
}

# -----------------------------------------------------------------------------
# MinIO client (mc)
# -----------------------------------------------------------------------------
install_mc() {
  if installed mc; then
    info "mc $(mc --version | head -1) already installed — skipping"
    return
  fi
  info "Installing MinIO client (mc)..."
  if [[ "$OS" == "debian" ]]; then
    curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc
    sudo install -m 0755 /tmp/mc /usr/local/bin/mc
    rm /tmp/mc
  else
    brew install minio/stable/mc
  fi
}

# -----------------------------------------------------------------------------
# Ansible (via pip — distro packages lag significantly)
# -----------------------------------------------------------------------------
install_ansible() {
  if installed ansible; then
    info "ansible $(ansible --version | head -1) already installed — skipping"
    return
  fi
  info "Installing Ansible via pip..."
  if [[ "$OS" == "debian" ]]; then
    # Use --break-system-packages on Python 3.11+ (Debian 12 / Ubuntu 24.04)
    pip3 install --user ansible --break-system-packages 2>/dev/null \
      || pip3 install --user ansible
    # Ensure ~/.local/bin is on PATH
    export PATH="$HOME/.local/bin:$PATH"
    for profile in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [[ -f "$profile" ]] && grep -q '.local/bin' "$profile" \
        || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$profile"
    done
  else
    brew install ansible
  fi
}

# -----------------------------------------------------------------------------
# Ansible Galaxy collections
# -----------------------------------------------------------------------------
install_ansible_collections() {
  info "Installing Ansible Galaxy collections..."
  ansible-galaxy collection install kubernetes.core community.general --ignore-errors
}

# -----------------------------------------------------------------------------
# SSH key for Ansible
# -----------------------------------------------------------------------------
generate_ssh_key() {
  KEY_PATH="$HOME/.ssh/k8s_ansible"
  if [[ -f "$KEY_PATH" ]]; then
    info "Ansible SSH key already exists at $KEY_PATH — skipping"
    return
  fi
  info "Generating Ansible SSH key pair..."
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "k8s-ansible"
  info "Public key (add to router DHCP reservations or trust list):"
  cat "${KEY_PATH}.pub"
  warn "Store the PRIVATE key ($KEY_PATH) as ANSIBLE_SSH_PRIVATE_KEY in GitHub Secrets."
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_versions() {
  echo ""
  info "=== Installed tool versions ==="
  installed tofu      && echo "  OpenTofu:  $(tofu version | head -1)"
  installed packer    && echo "  Packer:    $(packer version | head -1)"
  installed kubectl   && echo "  kubectl:   $(kubectl version --client --short 2>/dev/null)"
  installed helm      && echo "  Helm:      $(helm version --short)"
  installed argocd    && echo "  ArgoCD:    $(argocd version --client --short 2>/dev/null | head -1)"
  installed velero    && echo "  Velero:    $(velero version --client-only 2>/dev/null | head -1)"
  installed bao       && echo "  OpenBao:   $(bao version 2>/dev/null | head -1)"
  installed mc        && echo "  mc:        $(mc --version | head -1)"
  installed ansible   && echo "  Ansible:   $(ansible --version | head -1)"
  installed gh        && echo "  gh:        $(gh --version | head -1)"
  installed jq        && echo "  jq:        $(jq --version)"
  installed git       && echo "  git:       $(git --version)"
  echo ""
  warn "Restart your shell (or run: source ~/.bashrc) to pick up PATH changes."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  echo ""
  info "k8s-planning developer toolchain installer"
  echo ""

  detect_os

  [[ "$OS" == "macos" ]] && ensure_brew

  install_base
  install_gh
  install_opentofu
  install_packer
  install_kubectl
  install_helm
  install_argocd
  install_velero
  install_openbao
  install_mc
  install_ansible
  install_ansible_collections
  generate_ssh_key

  print_versions
}

main "$@"
