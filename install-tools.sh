#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Colours & logging
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
skip()  { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

is_installed() { command -v "$1" >/dev/null 2>&1; }

get_latest_release() {
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
        | grep '"tag_name"' \
        | sed -E 's/.*"([^"]+)".*/\1/'
}

# ---------------------------------------------------------------------------
# Architecture
# ---------------------------------------------------------------------------
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    x86_64)          ARCH="amd64" ;;
    aarch64|arm64)   ARCH="arm64" ;;
    *)               die "Unsupported architecture: $ARCH_RAW" ;;
esac

# ---------------------------------------------------------------------------
# OS & package manager detection
# ---------------------------------------------------------------------------
OS=$(uname -s)
PKG_MANAGER=""
DISTRO=""
USE_BREW=false

if [[ "$OS" == "Darwin" ]]; then
    USE_BREW=true
    PKG_MANAGER="brew"
    is_installed brew || die "Homebrew not found. Install it from https://brew.sh and re-run."
elif [[ "$OS" == "Linux" ]]; then
    if is_installed apt-get;  then PKG_MANAGER="apt";    DISTRO="debian"
    elif is_installed dnf;    then PKG_MANAGER="dnf";    DISTRO="fedora"
    elif is_installed pacman; then PKG_MANAGER="pacman"; DISTRO="arch"
    else die "No supported package manager found (apt / dnf / pacman)."
    fi
else
    die "Unsupported OS: $OS"
fi

# ---------------------------------------------------------------------------
# Homebrew prompt (Linux only)
# ---------------------------------------------------------------------------
if [[ "$OS" == "Linux" ]]; then
    echo
    echo "Homebrew on Linux can install tools not in distro repos."
    echo "  1) Install Homebrew now"
    echo "  2) Homebrew is already installed"
    echo "  3) Skip — use native package manager only"
    echo
    read -rp "Choose [1/2/3]: " _brew_choice
    case "$_brew_choice" in
        1)
            log "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            # Activate brew in this session
            for _brew_path in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
                [[ -x "$_brew_path" ]] && eval "$($_brew_path shellenv)" && USE_BREW=true && break
            done
            $USE_BREW || warn "Homebrew installed but not found in PATH — continuing without it"
            ;;
        2)
            if is_installed brew; then
                USE_BREW=true
            else
                # Try common locations
                for _brew_path in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
                    if [[ -x "$_brew_path" ]]; then
                        eval "$($_brew_path shellenv)"; USE_BREW=true; break
                    fi
                done
                $USE_BREW || warn "Homebrew not found in PATH — continuing without it"
            fi
            ;;
        3) log "Using native package manager only" ;;
        *) warn "Invalid choice — using native package manager only" ;;
    esac
fi

# ---------------------------------------------------------------------------
# yay check (Arch only)
# ---------------------------------------------------------------------------
HAS_YAY=false
[[ "$DISTRO" == "arch" ]] && is_installed yay && HAS_YAY=true

# ---------------------------------------------------------------------------
# Repo setup helpers (idempotent — no-op if already added)
# ---------------------------------------------------------------------------

_get_codename() {
    # Prefer /etc/os-release over lsb_release
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${VERSION_CODENAME:-$ID}"
    else
        lsb_release -cs
    fi
}

setup_hashicorp_apt() {
    [[ -f /etc/apt/sources.list.d/hashicorp.list ]] && return
    log "Adding HashiCorp apt repo"
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(_get_codename) main" \
        | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    sudo apt-get update -q
}

setup_hashicorp_dnf() {
    [[ -f /etc/yum.repos.d/hashicorp.repo ]] && return
    log "Adding HashiCorp dnf repo"
    sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo 2>/dev/null \
        || sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
}

setup_kubernetes_apt() {
    [[ -f /etc/apt/sources.list.d/kubernetes.list ]] && return
    log "Adding Kubernetes apt repo"
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
    sudo apt-get update -q
}

setup_kubernetes_dnf() {
    [[ -f /etc/yum.repos.d/kubernetes.repo ]] && return
    log "Adding Kubernetes dnf repo"
    sudo tee /etc/yum.repos.d/kubernetes.repo >/dev/null <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
EOF
}

setup_gh_apt() {
    [[ -f /etc/apt/sources.list.d/github-cli.list ]] && return
    log "Adding GitHub CLI apt repo"
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -q
}

setup_gh_dnf() {
    [[ -f /etc/yum.repos.d/gh-cli.repo ]] && return
    log "Adding GitHub CLI dnf repo"
    sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null \
        || sudo dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo
}

ensure_unzip() {
    is_installed unzip && return
    case "$PKG_MANAGER" in
        apt)    sudo apt-get install -y unzip ;;
        dnf)    sudo dnf install -y unzip ;;
        pacman) sudo pacman -S --noconfirm unzip ;;
        brew)   brew install unzip ;;
    esac
}

ensure_pip3() {
    is_installed pip3 && return
    log "Installing pip3"
    case "$PKG_MANAGER" in
        apt)    sudo apt-get install -y python3-pip ;;
        dnf)    sudo dnf install -y python3-pip ;;
        pacman) sudo pacman -S --noconfirm python-pip ;;
        brew)   brew install python3 ;;
    esac
}

# ---------------------------------------------------------------------------
# tofuenv
# ---------------------------------------------------------------------------
install_tofuenv() {
    if is_installed tofuenv; then skip "tofuenv"; return; fi

    if $USE_BREW; then
        log "Installing tofuenv via brew"; brew install tofuenv; ok "tofuenv"; return
    fi
    if [[ "$DISTRO" == "arch" ]] && $HAS_YAY; then
        log "Installing tofuenv via yay"; yay -S --noconfirm tofuenv; ok "tofuenv"; return
    fi

    log "Installing tofuenv from GitHub releases"
    local version; version=$(get_latest_release "tofuutils/tofuenv")
    local tmpdir; tmpdir=$(mktemp -d)
    curl -fsSL "https://github.com/tofuutils/tofuenv/archive/refs/tags/${version}.tar.gz" \
        -o "$tmpdir/tofuenv.tar.gz"
    tar -xzf "$tmpdir/tofuenv.tar.gz" -C "$tmpdir"
    sudo rm -rf /usr/local/tofuenv
    sudo mv "$tmpdir"/tofuenv-* /usr/local/tofuenv
    sudo ln -sf /usr/local/tofuenv/bin/tofuenv /usr/local/bin/tofuenv
    # tofu shim may not exist in all versions
    [[ -f /usr/local/tofuenv/bin/tofu ]] \
        && sudo ln -sf /usr/local/tofuenv/bin/tofu /usr/local/bin/tofu || true
    rm -rf "$tmpdir"
    ok "tofuenv $version"
}

# ---------------------------------------------------------------------------
# packer
# ---------------------------------------------------------------------------
install_packer() {
    if is_installed packer; then skip "packer"; return; fi

    if $USE_BREW; then
        log "Installing packer via brew"; brew install packer; ok "packer"; return
    fi
    case "$PKG_MANAGER" in
        apt)
            setup_hashicorp_apt
            sudo apt-get install -y packer
            ;;
        dnf)
            setup_hashicorp_dnf
            sudo dnf install -y packer
            ;;
        pacman)
            if $HAS_YAY; then yay -S --noconfirm packer
            else die "packer on Arch requires yay — install yay first: https://github.com/Jguer/yay"; fi
            ;;
    esac
    ok "packer"
}

# ---------------------------------------------------------------------------
# kubectl
# ---------------------------------------------------------------------------
install_kubectl() {
    if is_installed kubectl; then skip "kubectl"; return; fi

    if $USE_BREW; then
        log "Installing kubectl via brew"; brew install kubectl; ok "kubectl"; return
    fi
    case "$PKG_MANAGER" in
        apt)    setup_kubernetes_apt; sudo apt-get install -y kubectl ;;
        dnf)    setup_kubernetes_dnf; sudo dnf install -y kubectl ;;
        pacman) sudo pacman -S --noconfirm kubectl ;;
    esac
    ok "kubectl"
}

# ---------------------------------------------------------------------------
# helm
# ---------------------------------------------------------------------------
install_helm() {
    if is_installed helm; then skip "helm"; return; fi

    if $USE_BREW; then
        log "Installing helm via brew"; brew install helm; ok "helm"; return
    fi
    case "$PKG_MANAGER" in
        pacman) sudo pacman -S --noconfirm helm ;;
        *)
            log "Installing helm via official install script"
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            ;;
    esac
    ok "helm"
}

# ---------------------------------------------------------------------------
# argocd CLI
# ---------------------------------------------------------------------------
install_argocd() {
    if is_installed argocd; then skip "argocd"; return; fi

    if $USE_BREW; then
        log "Installing argocd via brew"; brew install argocd; ok "argocd"; return
    fi
    if [[ "$DISTRO" == "arch" ]] && $HAS_YAY; then
        log "Installing argocd via yay"; yay -S --noconfirm argocd-cli; ok "argocd"; return
    fi

    log "Installing argocd CLI from GitHub releases"
    local version; version=$(get_latest_release "argoproj/argo-cd")
    curl -fsSL \
        "https://github.com/argoproj/argo-cd/releases/download/${version}/argocd-linux-${ARCH}" \
        -o /tmp/argocd
    sudo install -m 0755 /tmp/argocd /usr/local/bin/argocd
    rm /tmp/argocd
    ok "argocd $version"
}

# ---------------------------------------------------------------------------
# velero CLI
# ---------------------------------------------------------------------------
install_velero() {
    if is_installed velero; then skip "velero"; return; fi

    if $USE_BREW; then
        log "Installing velero via brew"; brew install velero; ok "velero"; return
    fi
    if [[ "$DISTRO" == "arch" ]] && $HAS_YAY; then
        log "Installing velero via yay"; yay -S --noconfirm velero-bin; ok "velero"; return
    fi

    log "Installing velero CLI from GitHub releases"
    local version; version=$(get_latest_release "vmware-tanzu/velero")
    local tmpdir; tmpdir=$(mktemp -d)
    curl -fsSL \
        "https://github.com/vmware-tanzu/velero/releases/download/${version}/velero-${version}-linux-${ARCH}.tar.gz" \
        -o "$tmpdir/velero.tar.gz"
    tar -xzf "$tmpdir/velero.tar.gz" -C "$tmpdir" --strip-components=1
    sudo install -m 0755 "$tmpdir/velero" /usr/local/bin/velero
    rm -rf "$tmpdir"
    ok "velero $version"
}

# ---------------------------------------------------------------------------
# mc (MinIO client)
# ---------------------------------------------------------------------------
install_mc() {
    if is_installed mc; then skip "mc"; return; fi

    if $USE_BREW; then
        log "Installing mc via brew"; brew install minio/stable/mc; ok "mc"; return
    fi
    case "$PKG_MANAGER" in
        pacman)
            sudo pacman -S --noconfirm minio-client
            ;;
        *)
            log "Installing mc binary from dl.min.io"
            curl -fsSL "https://dl.min.io/client/mc/release/linux-${ARCH}/mc" -o /tmp/mc
            sudo install -m 0755 /tmp/mc /usr/local/bin/mc
            rm /tmp/mc
            ;;
    esac
    ok "mc"
}

# ---------------------------------------------------------------------------
# bao (OpenBao CLI)
# No brew tap exists — binary install everywhere.
# ---------------------------------------------------------------------------
install_bao() {
    if is_installed bao; then skip "bao"; return; fi

    if [[ "$DISTRO" == "arch" ]] && $HAS_YAY; then
        log "Installing bao via yay"; yay -S --noconfirm openbao-bin; ok "bao"; return
    fi

    log "Installing bao (OpenBao) from GitHub releases"
    local version; version=$(get_latest_release "openbao/openbao")
    local ver_no_v="${version#v}"

    case "$PKG_MANAGER" in
        apt)
            curl -fsSL \
                "https://github.com/openbao/openbao/releases/download/${version}/bao_${ver_no_v}_linux_${ARCH}.deb" \
                -o /tmp/bao.deb
            sudo dpkg -i /tmp/bao.deb
            rm /tmp/bao.deb
            ;;
        dnf)
            sudo dnf install -y \
                "https://github.com/openbao/openbao/releases/download/${version}/bao_${ver_no_v}_linux_${ARCH}.rpm"
            ;;
        *)
            # pacman without yay, or macOS (brew)
            ensure_unzip
            local os_lower; os_lower=$(uname -s | tr '[:upper:]' '[:lower:]')
            curl -fsSL \
                "https://github.com/openbao/openbao/releases/download/${version}/bao_${ver_no_v}_${os_lower}_${ARCH}.zip" \
                -o /tmp/bao.zip
            unzip -q /tmp/bao.zip bao -d /tmp/bao_extracted
            sudo install -m 0755 /tmp/bao_extracted/bao /usr/local/bin/bao
            rm -rf /tmp/bao.zip /tmp/bao_extracted
            ;;
    esac
    ok "bao $version"
}

# ---------------------------------------------------------------------------
# ansible (always via pip — distro packages lag)
# ---------------------------------------------------------------------------
install_ansible() {
    if is_installed ansible; then skip "ansible"; return; fi

    ensure_pip3
    log "Installing ansible via pip3"
    pip3 install --user ansible

    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
        warn "~/.local/bin added to PATH for this session — add it to your shell profile"
    fi
    ok "ansible"
}

# ---------------------------------------------------------------------------
# jq
# ---------------------------------------------------------------------------
install_jq() {
    if is_installed jq; then skip "jq"; return; fi
    case "$PKG_MANAGER" in
        apt)    sudo apt-get install -y jq ;;
        dnf)    sudo dnf install -y jq ;;
        pacman) sudo pacman -S --noconfirm jq ;;
        brew)   brew install jq ;;
    esac
    ok "jq"
}

# ---------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------
install_git() {
    if is_installed git; then skip "git"; return; fi
    case "$PKG_MANAGER" in
        apt)    sudo apt-get install -y git ;;
        dnf)    sudo dnf install -y git ;;
        pacman) sudo pacman -S --noconfirm git ;;
        brew)   brew install git ;;
    esac
    ok "git"
}

# ---------------------------------------------------------------------------
# curl
# ---------------------------------------------------------------------------
install_curl() {
    if is_installed curl; then skip "curl"; return; fi
    case "$PKG_MANAGER" in
        apt)    sudo apt-get install -y curl ;;
        dnf)    sudo dnf install -y curl ;;
        pacman) sudo pacman -S --noconfirm curl ;;
        brew)   : ;;  # built-in on macOS, brew path won't reach here
    esac
    ok "curl"
}

# ---------------------------------------------------------------------------
# gh (GitHub CLI)
# ---------------------------------------------------------------------------
install_gh() {
    if is_installed gh; then skip "gh"; return; fi

    if $USE_BREW; then
        log "Installing gh via brew"; brew install gh; ok "gh"; return
    fi
    case "$PKG_MANAGER" in
        apt)
            setup_gh_apt
            sudo apt-get install -y gh
            ;;
        dnf)
            setup_gh_dnf
            sudo dnf install -y gh
            ;;
        pacman)
            sudo pacman -S --noconfirm github-cli
            ;;
    esac
    ok "gh"
}

# ---------------------------------------------------------------------------
# ansible-galaxy collections
# ---------------------------------------------------------------------------
install_galaxy_collections() {
    if ! is_installed ansible-galaxy; then
        warn "ansible-galaxy not in PATH — skipping collection install (re-run after shell restart)"
        return
    fi
    log "Installing ansible-galaxy collections"
    ansible-galaxy collection install kubernetes.core community.general --upgrade
    ok "ansible-galaxy collections"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo
echo "================================================"
echo "  K8s Tooling Installer"
echo "  OS: $OS | Pkg mgr: $PKG_MANAGER | Brew: $USE_BREW"
echo "================================================"
echo

# curl and git first — other installs may need them
install_curl
install_git
install_jq

install_tofuenv
install_packer
install_kubectl
install_helm
install_argocd
install_velero
install_mc
install_bao
install_ansible
install_gh

install_galaxy_collections

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "================================================"
echo "  Summary"
echo "================================================"
_all_ok=true
for _tool in tofuenv packer kubectl helm argocd velero mc bao ansible jq git curl gh; do
    if is_installed "$_tool"; then
        echo -e "  ${GREEN}✓${NC} $_tool"
    else
        echo -e "  ${RED}✗${NC} $_tool  ← not in PATH (may need shell restart)"
        _all_ok=false
    fi
done
echo

if $_all_ok; then
    echo -e "${GREEN}All tools installed successfully.${NC}"
else
    echo -e "${YELLOW}Some tools are not in PATH. Open a new shell and re-check.${NC}"
fi
echo
