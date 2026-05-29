#!/usr/bin/env bash
set -euo pipefail

CONTAINER_RUNTIME=""

usage() {
  echo "Usage: $0 --docker | --podman"
  echo ""
  echo "  --docker   Install Docker as the container runtime"
  echo "  --podman   Install Podman as the container runtime"
  exit 1
}

if [[ $# -eq 0 ]]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker) CONTAINER_RUNTIME="docker"; shift ;;
    --podman) CONTAINER_RUNTIME="podman"; shift ;;
    *) echo "Unknown flag: $1"; usage ;;
  esac
done

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
err()     { echo "[ERROR] $*" >&2; exit 1; }

need_cmd() {
  if ! command -v "$1" &>/dev/null; then
    err "'$1' is required but not installed. Please install it first."
  fi
}

# macOS helpers

install_brew_pkg() {
  local pkg="$1"
  if brew list --formula "$pkg" &>/dev/null 2>&1 || brew list --cask "$pkg" &>/dev/null 2>&1; then
    info "$pkg already installed via Homebrew"
  else
    info "Installing $pkg via Homebrew..."
    brew install "$pkg"
  fi
}

# Linux helpers

detect_linux_pkg_manager() {
  if command -v apt-get &>/dev/null; then echo "apt"
  elif command -v dnf &>/dev/null;     then echo "dnf"
  elif command -v yum &>/dev/null;     then echo "yum"
  elif command -v pacman &>/dev/null;  then echo "pacman"
  else err "No supported package manager found (apt/dnf/yum/pacman)"; fi
}

pkg_install() {
  local pm="$1"; shift
  case "$pm" in
    apt)    sudo apt-get install -y "$@" ;;
    dnf)    sudo dnf install -y "$@" ;;
    yum)    sudo yum install -y "$@" ;;
    pacman) sudo pacman -Sy --noconfirm "$@" ;;
  esac
}

# kind

install_kind() {
  if command -v kind &>/dev/null; then
    info "kind $(kind version) already installed"
    return
  fi

  info "Installing kind..."
  local version
  version="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
    | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')"

  if [[ "$OS" == "darwin" ]]; then
    need_cmd brew
    install_brew_pkg kind
  else
    local url="https://kind.sigs.k8s.io/dl/${version}/kind-linux-${ARCH}"
    curl -fsSL "$url" -o /tmp/kind
    chmod +x /tmp/kind
    sudo mv /tmp/kind /usr/local/bin/kind
  fi
  success "kind installed: $(kind version)"
}

# kubectl
install_kubectl() {
  if command -v kubectl &>/dev/null; then
    info "kubectl $(kubectl version --client --short 2>/dev/null || kubectl version --client) already installed"
    return
  fi

  info "Installing kubectl..."

  if [[ "$OS" == "darwin" ]]; then
    need_cmd brew
    install_brew_pkg kubectl
  else
    local stable
    stable="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSL "https://dl.k8s.io/release/${stable}/bin/linux/${ARCH}/kubectl" -o /tmp/kubectl
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
  fi
  success "kubectl installed: $(kubectl version --client --short 2>/dev/null || true)"
}

# helm
install_helm() {
  if command -v helm &>/dev/null; then
    info "helm $(helm version --short) already installed"
    return
  fi

  info "Installing helm..."

  if [[ "$OS" == "darwin" ]]; then
    need_cmd brew
    install_brew_pkg helm
  else
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  success "helm installed: $(helm version --short)"
}

# docker
install_docker() {
  if command -v docker &>/dev/null; then
    info "Docker $(docker --version) already installed"
    return
  fi

  info "Installing Docker..."

  if [[ "$OS" == "darwin" ]]; then
    need_cmd brew
    if ! brew list --cask docker &>/dev/null 2>&1; then
      brew install --cask docker
    fi
    info "Docker Desktop installed. Launch it from Applications to start the daemon."
  else
    need_cmd curl
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER" || true
    info "Docker installed. You may need to log out and back in for group membership to take effect."
  fi
  success "Docker installed: $(docker --version 2>/dev/null || echo '(daemon not yet running)')"
}

# podman
install_podman() {
  if command -v podman &>/dev/null; then
    info "Podman $(podman --version) already installed"
    return
  fi

  info "Installing Podman..."

  if [[ "$OS" == "darwin" ]]; then
    need_cmd brew
    install_brew_pkg podman
    info "Podman installed. Run 'podman machine init && podman machine start' to start the VM."
  else
    local pm
    pm="$(detect_linux_pkg_manager)"
    case "$pm" in
      apt)
        sudo apt-get update -y
        pkg_install apt podman
        ;;
      dnf|yum)
        pkg_install "$pm" podman
        ;;
      pacman)
        pkg_install pacman podman
        ;;
    esac
  fi
  success "Podman installed: $(podman --version)"
}

# main

info "OS: $OS  ARCH: $ARCH  Container runtime: $CONTAINER_RUNTIME"

install_kind
install_kubectl
install_helm

case "$CONTAINER_RUNTIME" in
  docker) install_docker ;;
  podman) install_podman ;;
esac

echo ""
success "All dependencies installed successfully."
