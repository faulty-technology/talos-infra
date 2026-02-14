#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# bootstrap-install-argocd.sh
# Installs ArgoCD and applies the root App of Apps
# Run AFTER bootstrap-secrets.sh (which creates the GitHub App repo credential)
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
# 1. Install ArgoCD via Helm
# ---------------------------------------------------------------------------
echo ""
echo "=== ArgoCD ==="

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

if helm status argocd -n argocd &>/dev/null; then
	info "ArgoCD already installed, upgrading..."
fi

helm upgrade --install argocd argo/argo-cd \
	--namespace argocd \
	--create-namespace \
	--values "${MANIFESTS_DIR}/argocd/argocd-values.yaml" \
	--wait --timeout 300s

info "ArgoCD installed."

# ---------------------------------------------------------------------------
# 2. Wait for ArgoCD server to be ready
# ---------------------------------------------------------------------------
echo ""
echo "Waiting for ArgoCD server to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
info "ArgoCD server is ready."

# ---------------------------------------------------------------------------
# 3. Apply IngressRoute for ArgoCD UI
# ---------------------------------------------------------------------------
echo ""
echo "=== ArgoCD IngressRoute ==="
kubectl apply -f "${MANIFESTS_DIR}/argocd/argocd-ingress.yaml"
info "ArgoCD IngressRoute applied (argocd.faulty.technology)."

# ---------------------------------------------------------------------------
# 4. Retrieve initial admin password
# ---------------------------------------------------------------------------
echo ""
ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
	-o jsonpath="{.data.password}" 2>/dev/null | base64 -d) || true

if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
	info "Initial admin password retrieved."
else
	warn "Could not retrieve initial admin password (may have been deleted)."
fi

# ---------------------------------------------------------------------------
# 5. Apply root App of Apps
# ---------------------------------------------------------------------------
echo ""
echo "=== Root App of Apps ==="
kubectl apply -f "${MANIFESTS_DIR}/argocd/root-app.yaml"
info "Root App of Apps applied. ArgoCD will sync all workloads."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
info "ArgoCD installed and configured!"
echo "==========================================="
echo ""
echo "  ArgoCD UI: https://argocd.faulty.technology"
echo "    (requires Cloudflare Tunnel route + DNS CNAME)"
echo ""
echo "  Login:"
echo "    Username: admin"
if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
	echo "    Password: ${ADMIN_PASSWORD}"
fi
echo ""
echo "  Or port-forward locally:"
echo "    kubectl port-forward -n argocd svc/argocd-server 8080:80"
echo "    Then visit: http://localhost:8080"
echo ""
echo "  Check sync status:"
echo "    kubectl get applications -n argocd"
echo ""
echo "  Cloudflare Tunnel route (add in Zero Trust dashboard):"
echo "    Public hostname: argocd.faulty.technology"
echo "    Service: http://traefik.traefik.svc.cluster.local:80"
echo "    (Also need a DNS CNAME: argocd.faulty.technology → <tunnel-id>.cfargotunnel.com)"
echo ""
