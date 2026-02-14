#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# bootstrap-secrets.sh
# Creates Kubernetes secrets needed before ArgoCD syncs apps:
#   - cloudflared-token (Cloudflare Tunnel)
#   - argocd-repo-github-app (GitHub App org-level repo credentials)
#   - argocd-ghcr-oci (GHCR OCI registry credentials — only if charts are private)
# Run AFTER bootstrap-cluster.sh, BEFORE bootstrap-install-argocd.sh
#
# Prerequisites:
#   - Cluster bootstrapped and reachable (kubeconfig exists)
#   - CLOUDFLARE_TUNNEL_TOKEN set (or in Pulumi config)
#   - GitHub App created with "Repository contents: Read-only" permission
#   - App installed org-wide on faulty-technology
#   - Set these env vars (or they'll be read from Pulumi config):
#       GITHUB_APP_ID               — numeric App ID
#       GITHUB_APP_INSTALLATION_ID  — numeric Installation ID
#       GITHUB_APP_PRIVATE_KEY_FILE — path to the .pem file
#   - Optional (only needed if OCI Helm charts in GHCR are private):
#       GHCR_USERNAME — GitHub username for GHCR OCI auth
#       GHCR_TOKEN    — PAT with read:packages scope
# ---------------------------------------------------------------------------

SCRIPT_DIR=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/utils.sh"

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
export KUBECONFIG="${CONFIG_DIR}/kubeconfig"
export TALOSCONFIG="${CONFIG_DIR}/talosconfig"

[[ -f "$KUBECONFIG" ]] || error "Kubeconfig not found at ${KUBECONFIG}. Run bootstrap-cluster.sh first."
kubectl get nodes &>/dev/null || error "Cannot reach cluster. Is it running?"

# ---------------------------------------------------------------------------
# 1. Cloudflare Tunnel token secret
# ---------------------------------------------------------------------------
echo ""
echo "=== Cloudflare Tunnel Secret ==="

CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-$(cd "$PROJECT_DIR" && pulumi config get cloudflareTunnelToken 2>/dev/null || echo '')}"

if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
	warn "CLOUDFLARE_TUNNEL_TOKEN not set and not in Pulumi config. Skipping."
	echo "  Set CLOUDFLARE_TUNNEL_TOKEN or run: pulumi config set --secret cloudflareTunnelToken <token>"
else
	kubectl create namespace cloudflared 2>/dev/null || true
	kubectl create secret generic cloudflared-token \
		--namespace cloudflared \
		--from-literal=token="${CLOUDFLARE_TUNNEL_TOKEN}" \
		--dry-run=client -o yaml | kubectl apply -f -
	info "cloudflared-token secret created in cloudflared namespace."
fi

# ---------------------------------------------------------------------------
# 2. ArgoCD GitHub App repo credential secret
# ---------------------------------------------------------------------------
echo ""
echo "=== ArgoCD GitHub App Secret ==="

GITHUB_APP_ID="${GITHUB_APP_ID:-}"
GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:-}"
GITHUB_APP_PRIVATE_KEY_FILE="${GITHUB_APP_PRIVATE_KEY_FILE:-${CONFIG_DIR}/github-app-private-key.pem}"

if [[ -z "$GITHUB_APP_ID" || -z "$GITHUB_APP_INSTALLATION_ID" ]]; then
	error "GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID must be set."
fi

if [[ ! -f "$GITHUB_APP_PRIVATE_KEY_FILE" ]]; then
	error "GitHub App private key not found at ${GITHUB_APP_PRIVATE_KEY_FILE}"
fi

# Org-level URL — matches all repos under faulty-technology.
# Used by ArgoCD for git clones AND by ApplicationSet PR generator (appSecretName).
ORG_URL="https://github.com/faulty-technology"

kubectl create namespace argocd 2>/dev/null || true

# Clean up old SSH deploy key secret if it exists from previous attempts
if kubectl get secret argocd-repo-ssh -n argocd &>/dev/null; then
	kubectl delete secret argocd-repo-ssh -n argocd
	info "Removed stale SSH deploy key secret."
fi

# Create/update GitHub App credential template (idempotent via dry-run + apply)
kubectl create secret generic argocd-repo-github-app \
	--namespace argocd \
	--from-literal=type=git \
	--from-literal=url="${ORG_URL}" \
	--from-literal=githubAppID="${GITHUB_APP_ID}" \
	--from-literal=githubAppInstallationID="${GITHUB_APP_INSTALLATION_ID}" \
	--from-file=githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY_FILE}" \
	--dry-run=client -o yaml | kubectl apply -f -

kubectl label secret argocd-repo-github-app -n argocd \
	argocd.argoproj.io/secret-type=repo-creds --overwrite 2>/dev/null || true

info "argocd-repo-github-app secret created for ${ORG_URL} (org-level repo-creds)"

# ---------------------------------------------------------------------------
# 3. GHCR OCI registry credentials for Helm charts (optional)
#    Only needed if OCI charts in ghcr.io/faulty-technology/charts are private.
#    Currently public — skip unless GHCR_USERNAME + GHCR_TOKEN are set.
# ---------------------------------------------------------------------------
echo ""
echo "=== GHCR OCI Registry Credentials ==="

GHCR_USERNAME="${GHCR_USERNAME:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"

if [[ -z "$GHCR_TOKEN" || -z "$GHCR_USERNAME" ]]; then
	warn "GHCR_USERNAME and/or GHCR_TOKEN not set. Skipping GHCR OCI secret."
	echo "  Only needed if OCI Helm charts in GHCR are private."
else
	kubectl create secret generic argocd-ghcr-oci \
		--namespace argocd \
		--from-literal=type=helm \
		--from-literal=name=ghcr-faulty-technology \
		--from-literal=url="ghcr.io/faulty-technology/charts" \
		--from-literal=enableOCI="true" \
		--from-literal=username="${GHCR_USERNAME}" \
		--from-literal=password="${GHCR_TOKEN}" \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl label secret argocd-ghcr-oci -n argocd \
		argocd.argoproj.io/secret-type=repository --overwrite
	info "argocd-ghcr-oci secret created in argocd namespace."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
info "Kubernetes secrets created!"
echo "==========================================="
echo ""
echo "  Created:"
if [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
	echo "    - cloudflared-token (cloudflared namespace)"
else
	echo "    - cloudflared-token (skipped — no token)"
fi
echo "    - argocd-repo-github-app (argocd namespace, org-level repo-creds)"
if [[ -n "${GHCR_TOKEN:-}" && -n "${GHCR_USERNAME:-}" ]]; then
	echo "    - argocd-ghcr-oci (argocd namespace)"
else
	echo "    - argocd-ghcr-oci (skipped — charts are public)"
fi
echo ""
echo "  Next step:"
echo "    ./scripts/bootstrap-install-argocd.sh"
echo ""
