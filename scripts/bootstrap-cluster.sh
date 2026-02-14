#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# bootstrap-cluster.sh
# Run AFTER `pulumi up` succeeds.
# Generates Talos machine config, applies it, bootstraps the cluster.
# ---------------------------------------------------------------------------

SCRIPT_DIR=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/utils.sh"

# ---------------------------------------------------------------------------
# Pull values from Pulumi outputs
# ---------------------------------------------------------------------------
cd "$PROJECT_DIR"

NODE_IP="$(pulumi stack output nodePublicIp 2>/dev/null)" || error "Could not get nodePublicIp from Pulumi. Did you run 'pulumi up'?"
NODE_INSTANCE_ID="$(pulumi stack output nodeInstanceId 2>/dev/null)" || error "Could not get nodeInstanceId from Pulumi. Did you run 'pulumi up'?"
CLUSTER_NAME="$(pulumi config get clusterName 2>/dev/null || echo 'talos-homelab')"

# Get private IP — try Pulumi output first, fall back to AWS API
NODE_PRIVATE_IP="$(pulumi stack output nodePrivateIp 2>/dev/null || true)"
if [[ -z "$NODE_PRIVATE_IP" ]]; then
  warn "nodePrivateIp not in Pulumi outputs yet — querying AWS API..."
  NODE_PRIVATE_IP="$(aws ec2 describe-instances \
    --instance-ids "$NODE_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text 2>/dev/null)" \
    || error "Could not get private IP from AWS. Check your AWS credentials and instance status."
fi

info "Node public IP:  ${NODE_IP}"
info "Node private IP: ${NODE_PRIVATE_IP}"
info "Cluster: ${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# Generate secrets bundle (one-time, the ONLY file that must be backed up)
# ---------------------------------------------------------------------------
# secrets.yaml contains all CAs, keys, and tokens. Everything else
# (controlplane.yaml, talosconfig, kubeconfig) is derived from it and
# can be regenerated at any time.
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"

SECRETS_DIR="${PROJECT_DIR}/secrets"
mkdir -p "$SECRETS_DIR"

SECRETS_FILE="${SECRETS_DIR}/secrets.yaml"

if [[ ! -f "$SECRETS_FILE" ]]; then
  info "Generating cluster secrets bundle..."
  talosctl gen secrets -o "$SECRETS_FILE"
  info "Secrets bundle created at ${SECRETS_FILE}"
  echo ""
  warn "BACK UP ${SECRETS_FILE} NOW (e.g., 1Password, age-encrypted file)."
  echo "  This single file is the master key for your cluster."
  echo "  All other configs (talosconfig, controlplane.yaml, kubeconfig)"
  echo "  can be regenerated from it. If secrets.yaml is lost, the cluster"
  echo "  is unrecoverable."
  echo ""
else
  info "Secrets bundle already exists at ${SECRETS_FILE}"
fi

# ---------------------------------------------------------------------------
# Generate Talos machine configs (from secrets bundle)
# ---------------------------------------------------------------------------
# Since configs are derived from secrets.yaml, they can be safely regenerated
# whenever the IP changes, patches change, or you just want a clean slate.
# ---------------------------------------------------------------------------

# Remove derived configs to regenerate (secrets.yaml is preserved)
clean_configs() {
  rm -f "${CONFIG_DIR}/controlplane.yaml" \
       "${CONFIG_DIR}/worker.yaml" \
       "${CONFIG_DIR}/talosconfig" \
       "${CONFIG_DIR}/patch-single-node.yaml" \
       "${CONFIG_DIR}/kubeconfig"
}

REGEN_CONFIGS=false

if [[ -f "${CONFIG_DIR}/controlplane.yaml" ]]; then
  # Detect if IP changed — configs have wrong endpoint baked in
  if ! grep -q "${NODE_IP}" "${CONFIG_DIR}/controlplane.yaml"; then
    warn "Node IP changed — regenerating configs from secrets bundle..."
    REGEN_CONFIGS=true
  else
    warn "Talos configs already exist in ${CONFIG_DIR}/"
    echo "  (Configs can be safely regenerated from secrets.yaml at any time.)"
    echo ""

    # Check if node is configured — offer reset option
    export TALOSCONFIG="${CONFIG_DIR}/talosconfig"
    talosctl config endpoint "$NODE_IP"
    talosctl config node "$NODE_PRIVATE_IP"

    if talosctl --talosconfig "$TALOSCONFIG" version &>/dev/null; then
      warn "Node is already configured and responding."
      echo ""
      echo "  Options:"
      echo "    r) Reset node to maintenance mode and regenerate configs"
      echo "    a) Re-apply existing configs (keep current state)"
      echo "    q) Quit"
      echo ""
      read -rp "  Choose [r/a/q]: " choice
      case "$choice" in
        r|R)
          warn "Resetting node to maintenance mode..."
          talosctl --talosconfig "$TALOSCONFIG" reset --graceful=false --reboot \
            || error "Failed to reset node. You may need to 'pulumi destroy && pulumi up' to start fresh."
          info "Node is resetting. Waiting 30s for it to enter maintenance mode..."
          sleep 30
          REGEN_CONFIGS=true
          ;;
        a|A)
          info "Keeping existing configs. Will re-apply to node."
          ;;
        *)
          echo "Aborted."
          exit 0
          ;;
      esac
    else
      read -rp "  Regenerate configs? (y/N): " confirm
      if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        REGEN_CONFIGS=true
      else
        info "Keeping existing configs."
      fi
    fi
  fi
else
  REGEN_CONFIGS=true
fi

if [[ "$REGEN_CONFIGS" == "true" ]]; then
  clean_configs
  info "Generating Talos machine configs from secrets bundle..."

  talosctl gen config "$CLUSTER_NAME" "https://${NODE_IP}:6443" \
    --with-secrets "$SECRETS_FILE" \
    --output-dir "$CONFIG_DIR" \
    --with-docs=false \
    --with-examples=false

  info "Configs generated in ${CONFIG_DIR}/"
fi

# ---------------------------------------------------------------------------
# Patch: Allow workloads on control plane (single-node mode)
# ---------------------------------------------------------------------------
# By default Talos control plane nodes have a NoSchedule taint.
# For Phase 0 single-node, we need to remove it so pods can schedule here.
# ---------------------------------------------------------------------------
PATCH_FILE="${CONFIG_DIR}/patch-single-node.yaml"

# Always regenerate the patch (NODE_IP may change between runs)
info "Creating single-node patch (allow scheduling on control plane)..."
cat > "$PATCH_FILE" <<YAML
cluster:
  allowSchedulingOnControlPlanes: true
machine:
  # Include the public EIP in the Talos API server cert SANs.
  # Without this, mTLS fails because the server cert only contains
  # the private hostname/IP (the EC2 instance doesn't see the EIP).
  certSANs:
    - ${NODE_IP}
  # Use AWS time servers for accurate time
  time:
    servers:
      - 169.254.169.123
  features:
    kubePrism:
      enabled: true
      port: 7445
YAML
info "Patch file created."

# ---------------------------------------------------------------------------
# Configure talosctl BEFORE apply (so no stale env/default config interferes)
# ---------------------------------------------------------------------------
# CRITICAL: endpoint vs node distinction for AWS EIP setups:
#   endpoint = EIP (public IP you connect TO from outside)
#   node     = private IP (what Talos recognizes as itself internally)
#
# The EC2 instance only sees its private IP on the network interface — the EIP
# is NAT'd at the VPC Internet Gateway. If "node" is set to the EIP, Talos
# doesn't recognize it as itself and tries to proxy the gRPC request outbound
# to the EIP, which fails (AWS doesn't support hairpin NAT through the IGW).
# ---------------------------------------------------------------------------
export TALOSCONFIG="${CONFIG_DIR}/talosconfig"

talosctl config endpoint "$NODE_IP"
talosctl config node "$NODE_PRIVATE_IP"

info "talosctl endpoint: ${NODE_IP} (public EIP)"
info "talosctl node:     ${NODE_PRIVATE_IP} (private IP — what Talos sees as itself)"

# ---------------------------------------------------------------------------
# Wait for node to become reachable and detect its state
# ---------------------------------------------------------------------------
# A fresh Talos AMI boots into maintenance mode (no mTLS, port 50000).
# A previously configured node requires mTLS via talosconfig.
# We must detect which state the node is in before applying config.
# ---------------------------------------------------------------------------
echo ""
warn "Waiting for node to become reachable (can take 1-3 minutes)..."

NODE_MODE=""
MAX_ATTEMPTS=60
for i in $(seq 1 $MAX_ATTEMPTS); do
  # Try configured mode (node already has config, requires mTLS).
  # Must use --nodes with private IP — Talos only recognizes its private IP
  # as itself. Using the EIP causes a proxy loop and timeout.
  if talosctl --talosconfig "$TALOSCONFIG" --nodes "$NODE_PRIVATE_IP" version &>/dev/null; then
    NODE_MODE="configured"
    info "Node is already configured (Talos API responding with mTLS)."
    break
  fi
  # Check maintenance mode — version API isn't implemented in maintenance mode
  # on Talos v1.12+, but the server still responds with "maintenance" in the error.
  # Any response (success or maintenance error) means the node is reachable.
  # Note: --insecure uses --nodes with the EIP (direct TCP, no gRPC proxy).
  if INSECURE_OUT=$(talosctl version --insecure --nodes "$NODE_IP" 2>&1); then
    NODE_MODE="maintenance"
    info "Node is in maintenance mode (fresh boot)."
    break
  elif echo "$INSECURE_OUT" | grep -qi "maintenance"; then
    NODE_MODE="maintenance"
    info "Node is in maintenance mode (fresh boot)."
    break
  fi
  if (( i % 10 == 0 )); then
    echo "  Still waiting... (${i}/${MAX_ATTEMPTS})"
  fi
  sleep 5
done

if [[ -z "$NODE_MODE" ]]; then
  echo ""
  echo "  Neither maintenance mode (--insecure) nor mTLS connections succeeded."
  echo "  Possible causes:"
  echo "    - Instance hasn't finished booting yet"
  echo "    - Port 50000 is not open in the security group"
  echo "    - Configs were regenerated but node still has old PKI (destroy & recreate the instance)"
  error "Node did not become reachable after $((MAX_ATTEMPTS * 5)) seconds."
fi

# ---------------------------------------------------------------------------
# Apply config to the node
# ---------------------------------------------------------------------------
echo ""
info "Applying Talos config to ${NODE_IP} (mode: ${NODE_MODE})..."
echo "  This may take 30-60 seconds while the node configures itself."
echo ""

if [[ "$NODE_MODE" == "maintenance" ]]; then
  talosctl apply-config \
    --insecure \
    --nodes "$NODE_IP" \
    --file "${CONFIG_DIR}/controlplane.yaml" \
    --config-patch @"$PATCH_FILE"
else
  # Node already configured — apply as a config update via mTLS
  # Use private IP for --nodes (Talos gRPC proxy recognizes private IP as itself)
  talosctl apply-config \
    --talosconfig "$TALOSCONFIG" \
    --nodes "$NODE_PRIVATE_IP" \
    --file "${CONFIG_DIR}/controlplane.yaml" \
    --config-patch @"$PATCH_FILE"
fi

info "Config applied successfully."

# ---------------------------------------------------------------------------
# Wait for Talos API post-apply (node reboots into configured mode with mTLS)
# ---------------------------------------------------------------------------
echo ""
warn "Waiting for Talos API to come up after config apply (can take 1-2 minutes)..."

TALOS_API_READY=false
for i in $(seq 1 $MAX_ATTEMPTS); do
  if talosctl --talosconfig "$TALOSCONFIG" --nodes "$NODE_PRIVATE_IP" version &>/dev/null; then
    TALOS_API_READY=true
    info "Talos API is responding."
    break
  fi
  if (( i % 10 == 0 )); then
    echo "  Still waiting... (${i}/${MAX_ATTEMPTS})"
  fi
  sleep 5
done

if [[ "$TALOS_API_READY" != "true" ]]; then
  error "Talos API did not come back after config apply ($((MAX_ATTEMPTS * 5))s). Check instance status in the AWS console."
fi

# ---------------------------------------------------------------------------
# Bootstrap etcd (only needed once, on first control plane node)
# ---------------------------------------------------------------------------
echo ""
info "Bootstrapping etcd cluster..."

if BOOTSTRAP_OUTPUT=$(talosctl --talosconfig "$TALOSCONFIG" bootstrap 2>&1); then
  info "etcd bootstrap initiated."
else
  if echo "$BOOTSTRAP_OUTPUT" | grep -qi "already"; then
    warn "Bootstrap already completed (this is fine if re-running the script)."
  else
    echo "$BOOTSTRAP_OUTPUT"
    error "etcd bootstrap failed. See output above."
  fi
fi

# ---------------------------------------------------------------------------
# Wait for Kubernetes API
# ---------------------------------------------------------------------------
warn "Waiting for Kubernetes API to come up (1-2 minutes)..."

KUBECONFIG_READY=false
for i in $(seq 1 60); do
  if talosctl --talosconfig "$TALOSCONFIG" kubeconfig "${CONFIG_DIR}/kubeconfig" --force 2>/dev/null; then
    KUBECONFIG_READY=true
    break
  fi
  if (( i % 10 == 0 )); then
    echo "  Still waiting for Kubernetes API... (${i}/60)"
  fi
  sleep 5
done

if [[ "$KUBECONFIG_READY" != "true" ]]; then
  error "Kubernetes API did not become available after 300 seconds. Run 'talosctl --talosconfig ${TALOSCONFIG} health' to diagnose."
fi

# ---------------------------------------------------------------------------
# Verify cluster
# ---------------------------------------------------------------------------
export KUBECONFIG="${CONFIG_DIR}/kubeconfig"

echo ""
info "Checking cluster health..."

# Wait for the node to be Ready
NODE_READY=false
for i in $(seq 1 30); do
  if kubectl get nodes 2>/dev/null | grep -q " Ready"; then
    NODE_READY=true
    break
  fi
  sleep 5
done

echo ""
if [[ "$NODE_READY" == "true" ]]; then
  kubectl get nodes -o wide
  echo ""
  kubectl get pods -A
else
  kubectl get nodes -o wide 2>/dev/null || true
  echo ""
  error "Node did not reach Ready state after 150 seconds. Run 'kubectl describe nodes' and 'talosctl --talosconfig ${TALOSCONFIG} dmesg' to diagnose."
fi

# ---------------------------------------------------------------------------
# Post-bootstrap health check (talosctl health is correct HERE, after bootstrap)
# ---------------------------------------------------------------------------
echo ""
warn "Running cluster health check..."

if talosctl --talosconfig "$TALOSCONFIG" health --wait-timeout 120s --server=false \
    --control-plane-nodes "$NODE_PRIVATE_IP" --worker-nodes=""; then
  info "Cluster health check passed."
else
  warn "Cluster health check did not pass within timeout."
  echo "  This can happen on freshly bootstrapped clusters that are still stabilizing."
  echo "  Verify manually: talosctl --talosconfig ${TALOSCONFIG} health"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
info "Cluster bootstrap complete!"
echo "==========================================="
echo ""
echo "  Talos config:  export TALOSCONFIG=${CONFIG_DIR}/talosconfig"
echo "  Kubeconfig:    export KUBECONFIG=${CONFIG_DIR}/kubeconfig"
echo ""
echo "  Quick aliases (add to your shell rc):"
echo ""
echo "    export TALOSCONFIG=${CONFIG_DIR}/talosconfig"
echo "    export KUBECONFIG=${CONFIG_DIR}/kubeconfig"
echo ""
echo "  Next step: ./scripts/bootstrap-secrets.sh"
echo ""

# ---------------------------------------------------------------------------
# Security reminder
# ---------------------------------------------------------------------------
echo ""
warn "IMPORTANT: Back up your secrets bundle!"
echo "  ${SECRETS_FILE}  ← the ONLY file you must protect"
echo ""
echo "  • Already in .gitignore (never commit this)"
echo "  • Store it in 1Password, Vault, or an age-encrypted file"
echo "  • All other configs (talosconfig, controlplane.yaml, kubeconfig)"
echo "    can be regenerated from secrets.yaml at any time"
echo "  • If secrets.yaml is lost, the cluster is unrecoverable"
echo "  • If you 'pulumi destroy', delete secrets.yaml too and regenerate"
echo "    on next bootstrap (avoids stale cluster discovery entries)"
echo ""
