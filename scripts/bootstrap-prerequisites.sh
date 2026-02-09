#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# bootstrap-prerequisites.sh
# Installs: AWS CLI v2, talosctl, kubectl, helm
# Run once on your local machine before pulumi up
# ---------------------------------------------------------------------------

SCRIPT_DIR=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/utils.sh"

# Normalize arch
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# AWS CLI v2
# ---------------------------------------------------------------------------
install_aws_cli() {
  if command -v aws &>/dev/null; then
    info "AWS CLI already installed: $(aws --version)"
    return
  fi

  warn "Installing AWS CLI v2..."
  case "$OS" in
    Darwin)
      curl -sL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg
      sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
      rm /tmp/AWSCLIV2.pkg
      ;;
    Linux)
      curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
      cd /tmp && unzip -qo awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip
      cd -
      ;;
    *) error "Unsupported OS for AWS CLI install: $OS"; exit 1 ;;
  esac
  info "AWS CLI installed: $(aws --version)"
}

# ---------------------------------------------------------------------------
# talosctl
# ---------------------------------------------------------------------------
install_talosctl() {
  # Use latest stable — matches the AMI filter in index.ts
  local TALOS_VERSION="v1.12.3"

  if command -v talosctl &>/dev/null; then
    local current
    current="$(talosctl version --client 2>/dev/null | grep 'Tag:' | awk '{print $2}' || echo 'unknown')"
    info "talosctl already installed: ${current}"
    if [[ "$current" != "$TALOS_VERSION" ]]; then
      warn "Expected ${TALOS_VERSION}, got ${current}. Upgrading..."
    else
      return
    fi
  fi

  warn "Installing talosctl ${TALOS_VERSION}..."
  local url
  case "$OS" in
    Darwin) url="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-darwin-${ARCH}" ;;
    Linux)  url="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-${ARCH}" ;;
    *) error "Unsupported OS: $OS"; exit 1 ;;
  esac

  curl -sL "$url" -o /tmp/talosctl
  chmod +x /tmp/talosctl
  sudo mv /tmp/talosctl /usr/local/bin/talosctl
  info "talosctl installed: $(talosctl version --client 2>/dev/null | grep 'Tag:' | awk '{print $2}')"
}

# ---------------------------------------------------------------------------
# kubectl
# ---------------------------------------------------------------------------
install_kubectl() {
  if command -v kubectl &>/dev/null; then
    info "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
    return
  fi

  warn "Installing kubectl..."
  local k8s_version
  k8s_version="$(curl -sL https://dl.k8s.io/release/stable.txt)"

  local os_lower
  os_lower="$(echo "$OS" | tr '[:upper:]' '[:lower:]')"

  curl -sL "https://dl.k8s.io/release/${k8s_version}/bin/${os_lower}/${ARCH}/kubectl" -o /tmp/kubectl
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
  info "kubectl installed: $(kubectl version --client 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------------------
# helm
# ---------------------------------------------------------------------------
install_helm() {
  if command -v helm &>/dev/null; then
    info "Helm already installed: $(helm version --short)"
    return
  fi

  warn "Installing Helm..."
  curl -sL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  info "Helm installed: $(helm version --short)"
}

# ---------------------------------------------------------------------------
# Run installations
# ---------------------------------------------------------------------------
echo ""
echo "=== Talos Cluster Prerequisites ==="
echo ""

install_aws_cli
install_talosctl
install_kubectl
install_helm

echo ""
echo "=== Checking AWS Configuration ==="
echo ""

if aws sts get-caller-identity &>/dev/null; then
  info "AWS credentials configured:"
  aws sts get-caller-identity --output table
else
  warn "AWS credentials not configured yet."
  echo ""
  echo "  Run:  aws configure"
  echo ""
  echo "  You'll need:"
  echo "    - AWS Access Key ID"
  echo "    - AWS Secret Access Key"
  echo "    - Default region: us-east-1"
  echo "    - Default output: json"
  echo ""
  echo "  To create an access key:"
  echo "    1. Go to AWS Console → IAM → Users → your user → Security credentials"
  echo "    2. Create access key → CLI use case"
  echo ""
  echo "  After configuring, re-run this script to verify."
  exit 1
fi

echo ""
info "All prerequisites installed! Next steps:"
echo ""
echo "  1. cd into this directory"
echo "  2. npm install"
echo "  3. pulumi stack init dev"
echo "  4. pulumi up"
echo "  5. ./scripts/bootstrap-cluster.sh"
echo ""
