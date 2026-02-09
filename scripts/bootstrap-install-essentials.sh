#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# bootstrap-install-essentials.sh
# Installs: EBS CSI driver, StorageClass, Traefik, cloudflared, metrics-server
# Run AFTER bootstrap-cluster.sh
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

mkdir -p "$MANIFESTS_DIR"

NODE_IP="$(cd "$PROJECT_DIR" && pulumi stack output nodePublicIp 2>/dev/null)" || error "Could not get nodePublicIp"
CLUSTER_NAME="$(cd "$PROJECT_DIR" && pulumi config get clusterName 2>/dev/null || echo 'talos-homelab')"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-$(cd "$PROJECT_DIR" && pulumi config get cloudflareTunnelToken 2>/dev/null || echo '')}"

info "Connected to cluster at ${NODE_IP}"

# ---------------------------------------------------------------------------
# 1. AWS EBS CSI Driver
# ---------------------------------------------------------------------------
echo ""
echo "=== EBS CSI Driver ==="

helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver 2>/dev/null || true
helm repo update aws-ebs-csi-driver

if helm status aws-ebs-csi-driver -n kube-system &>/dev/null; then
  info "EBS CSI driver already installed, upgrading..."
fi

helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set "controller.replicaCount=1" \
  --set "node.tolerateAllTaints=true" \
  --wait --timeout 120s

info "EBS CSI driver installed."

# Create gp3 StorageClass
cat > "${MANIFESTS_DIR}/storageclass-gp3.yaml" <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
YAML

kubectl apply -f "${MANIFESTS_DIR}/storageclass-gp3.yaml"

# Remove the default gp2 class if present (avoid two defaults)
if kubectl get storageclass gp2 &>/dev/null; then
  kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
fi

info "gp3 StorageClass created (default, encrypted, retain)."

# ---------------------------------------------------------------------------
# 2. Metrics Server (basic monitoring — enables kubectl top)
# ---------------------------------------------------------------------------
echo ""
echo "=== Metrics Server ==="

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update metrics-server

helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set "args={--kubelet-insecure-tls}" \
  --set "resources.requests.cpu=25m" \
  --set "resources.requests.memory=64Mi" \
  --set "resources.limits.memory=128Mi" \
  --wait --timeout 120s

info "Metrics server installed. 'kubectl top nodes/pods' will work shortly."

# ---------------------------------------------------------------------------
# 3. Traefik Ingress Controller
# ---------------------------------------------------------------------------
echo ""
echo "=== Traefik ==="

helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
helm repo update traefik

cat > "${MANIFESTS_DIR}/traefik-values.yaml" <<'YAML'
# Traefik values for single-node Talos + Cloudflare Tunnel setup
# No LoadBalancer needed — cloudflared connects directly to Traefik's ClusterIP

service:
  type: ClusterIP

# Single replica for Phase 0
deployment:
  replicas: 1

# Resource limits for t3a.small
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi

# Enable dashboard (access via port-forward for debugging)
ingressRoute:
  dashboard:
    enabled: true
    matchRule: "PathPrefix(`/dashboard`) || PathPrefix(`/api`)"
    entryPoints:
      - traefik

ports:
  web:
    port: 8000
    exposedPort: 80
  websecure:
    port: 8443
    exposedPort: 443
  traefik:
    port: 9000
    expose:
      default: false

logs:
  general:
    level: INFO
  access:
    enabled: true
YAML

helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --values "${MANIFESTS_DIR}/traefik-values.yaml" \
  --wait --timeout 120s

info "Traefik installed as ClusterIP service."
echo "  Dashboard: kubectl --kubeconfig .talos/kubeconfig port-forward -n traefik deploy/traefik 9000:9000"
echo "  Then visit: http://localhost:9000/dashboard/"

# ---------------------------------------------------------------------------
# 4. Cloudflare Tunnel (cloudflared)
# ---------------------------------------------------------------------------
echo ""
echo "=== Cloudflare Tunnel ==="

# Check if the user has a tunnel token
if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
  warn "CLOUDFLARE_TUNNEL_TOKEN not set. Skipping cloudflared install."
  echo ""
  echo "  To set up cloudflared later:"
  echo "    1. Create a tunnel in Cloudflare Zero Trust dashboard"
  echo "    2. Copy the tunnel token"
  echo "    3. Re-run with: CLOUDFLARE_TUNNEL_TOKEN=<token> $0"
  echo ""
  echo "  Or manually:"
  echo "    kubectl create namespace cloudflared"
  echo "    kubectl create secret generic cloudflared-token -n cloudflared \\"
  echo "      --from-literal=token=<your-tunnel-token>"
  echo "    kubectl apply -f manifests/cloudflared.yaml"
  echo ""
else
  # Create namespace and secret
  kubectl create namespace cloudflared 2>/dev/null || true
  kubectl create secret generic cloudflared-token \
    --namespace cloudflared \
    --from-literal=token="${CLOUDFLARE_TUNNEL_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Deploy cloudflared
  cat > "${MANIFESTS_DIR}/cloudflared.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflared
  labels:
    app: cloudflared
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args:
            - tunnel
            - --no-autoupdate
            - run
            - --token
            - $(TUNNEL_TOKEN)
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflared-token
                  key: token
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 5
            periodSeconds: 10
YAML

  kubectl apply -f "${MANIFESTS_DIR}/cloudflared.yaml"
  info "cloudflared deployed. Tunnel connecting to Cloudflare edge..."
  echo "  Check status: kubectl logs -n cloudflared -l app=cloudflared -f"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
info "Essential components installed!"
echo "==========================================="
echo ""
echo "  Installed:"
echo "    • EBS CSI driver (gp3 StorageClass, default)"
echo "    • Metrics Server (kubectl top nodes/pods)"
echo "    • Traefik (ClusterIP, ready for Cloudflare Tunnel)"
if [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
  echo "    • cloudflared (tunnel connecting)"
else
  echo "    • cloudflared (skipped — set CLOUDFLARE_TUNNEL_TOKEN to install)"
fi
echo ""
echo "  Verify:"
echo "    kubectl get pods -A"
echo "    kubectl get storageclass"
echo "    kubectl top nodes   (wait ~60s after install)"
echo ""
echo "  Next steps:"
echo "    kubectl apply -f manifests/test-app.yaml  (test ingress)"
echo "    ./scripts/bootstrap-install-argocd.sh     (install ArgoCD for GitOps)"
echo ""
