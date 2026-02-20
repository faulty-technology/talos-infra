#!/usr/bin/env bash
# Debugging script for ArgoCD notifications / GitHub deployment status issues.
# Run with KUBECONFIG set: source .env.local && export KUBECONFIG=$(pwd)/.talos/kubeconfig

set -euo pipefail

echo "=== 1. Notifications controller pod ==="
kubectl get pods -n argocd | grep notifications

echo ""
echo "=== 2. Controller logs (last 2h) ==="
kubectl logs -n argocd deploy/argocd-notifications-controller --since=2h 2>&1 | tail -40

echo ""
echo "=== 3. App-repo Application annotations ==="
kubectl get applications -n argocd hello-k8s subnet-cheat-sheet belowthefold-rocks \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations}{"\n"}{end}' 2>/dev/null \
  || echo "(no matching applications found)"

echo ""
echo "=== 4. GitHub service config in notifications ConfigMap ==="
kubectl get cm -n argocd argocd-notifications-cm \
  -o jsonpath='{.data.service\.github}' 2>/dev/null \
  || echo "(ConfigMap not found or key missing)"
