#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# ops-etcd-restore.sh
# Restores an etcd snapshot from a local file or S3.
# Usage: ./scripts/ops-etcd-restore.sh <snapshot-file | s3://bucket/key>
# ---------------------------------------------------------------------------

SCRIPT_DIR=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/utils.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
	echo "Usage: $0 <snapshot-file | s3://bucket/key>"
	echo ""
	echo "Examples:"
	echo "  $0 .talos/snapshots/etcd-snapshot-20250101T120000Z.db"
	echo "  $0 s3://talos-homelab-etcd-backups/snapshots/etcd-snapshot-20250101T120000Z.db"
	exit 1
fi

SNAPSHOT_ARG="$1"

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
command -v talosctl >/dev/null 2>&1 || error "talosctl not found. Run ./scripts/bootstrap-prerequisites.sh"

if [[ -z "${TALOSCONFIG:-}" ]]; then
	export TALOSCONFIG="${CONFIG_DIR}/talosconfig"
fi
[[ -f "$TALOSCONFIG" ]] || error "TALOSCONFIG not found at ${TALOSCONFIG}. Has the cluster been bootstrapped?"

# ---------------------------------------------------------------------------
# Download from S3 if needed
# ---------------------------------------------------------------------------
if [[ "$SNAPSHOT_ARG" == s3://* ]]; then
	command -v aws >/dev/null 2>&1 || error "AWS CLI not found. Run ./scripts/bootstrap-prerequisites.sh"
	SNAPSHOT_DIR="${CONFIG_DIR}/snapshots"
	mkdir -p "$SNAPSHOT_DIR"
	LOCAL_SNAPSHOT="${SNAPSHOT_DIR}/etcd-restore-$(date -u +%Y%m%dT%H%M%SZ).db"
	info "Downloading ${SNAPSHOT_ARG}..."
	aws s3 cp "$SNAPSHOT_ARG" "$LOCAL_SNAPSHOT" || error "S3 download failed"
	info "Downloaded to ${LOCAL_SNAPSHOT}"
else
	LOCAL_SNAPSHOT="$SNAPSHOT_ARG"
fi

[[ -f "$LOCAL_SNAPSHOT" ]] || error "Snapshot file not found: ${LOCAL_SNAPSHOT}"

SNAPSHOT_SIZE="$(stat --printf='%s' "$LOCAL_SNAPSHOT" 2>/dev/null || stat -f '%z' "$LOCAL_SNAPSHOT")"
info "Snapshot: ${LOCAL_SNAPSHOT} ($(numfmt --to=iec "$SNAPSHOT_SIZE" 2>/dev/null || echo "${SNAPSHOT_SIZE} bytes"))"

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
echo ""
warn "⚠  This will RESET the node and restore etcd from the snapshot."
warn "   The cluster will be unavailable during the restore process."
warn "   All data written after the snapshot was taken will be LOST."
echo ""
read -rp "Type 'yes' to proceed: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
	echo "Aborted."
	exit 0
fi

# ---------------------------------------------------------------------------
# Get node info from Pulumi
# ---------------------------------------------------------------------------
cd "$PROJECT_DIR"
NODE_IP="$(pulumi stack output nodePublicIp 2>/dev/null)" || error "Could not get nodePublicIp from Pulumi."
NODE_PRIVATE_IP="$(pulumi stack output nodePrivateIp 2>/dev/null)" || error "Could not get nodePrivateIp from Pulumi."

# ---------------------------------------------------------------------------
# Restore procedure
# ---------------------------------------------------------------------------
echo ""
info "Step 1/4: Resetting the node..."
talosctl reset --graceful=false --reboot || error "Node reset failed"

info "Waiting for node to enter maintenance mode..."
READY=false
for i in $(seq 1 60); do
	if talosctl version --insecure --nodes "$NODE_IP" 2>&1 | grep -qi "maintenance"; then
		READY=true
		break
	fi
	sleep 5
done
if [[ "$READY" != true ]]; then
	error "Node did not enter maintenance mode within 5 minutes"
fi
info "Node is in maintenance mode"

info "Step 2/4: Re-applying machine config..."
[[ -f "${CONFIG_DIR}/controlplane.yaml" ]] || error "controlplane.yaml not found in ${CONFIG_DIR}"

PATCH_FILE="${CONFIG_DIR}/patch-single-node.yaml"
if [[ -f "$PATCH_FILE" ]]; then
	talosctl apply-config --insecure --nodes "$NODE_IP" \
		--file "${CONFIG_DIR}/controlplane.yaml" \
		--config-patch @"$PATCH_FILE" || error "apply-config failed"
else
	warn "Single-node patch not found at ${PATCH_FILE} — applying without it."
	warn "Re-run bootstrap-cluster.sh after restore to regenerate the patch."
	talosctl apply-config --insecure --nodes "$NODE_IP" \
		--file "${CONFIG_DIR}/controlplane.yaml" || error "apply-config failed"
fi

info "Waiting for node to reboot with config..."
sleep 15

info "Step 3/4: Bootstrapping etcd from snapshot..."
BOOTSTRAP_READY=false
for i in $(seq 1 60); do
	if talosctl version 2>/dev/null | grep -q "Tag:"; then
		BOOTSTRAP_READY=true
		break
	fi
	sleep 5
done
if [[ "$BOOTSTRAP_READY" != true ]]; then
	error "Node did not become reachable within 5 minutes after config apply"
fi

talosctl bootstrap --recover-from="$LOCAL_SNAPSHOT" || error "Bootstrap with recovery failed"

info "Step 4/4: Waiting for cluster to be ready..."
CLUSTER_READY=false
for i in $(seq 1 60); do
	if talosctl health --wait-timeout 10s 2>/dev/null; then
		CLUSTER_READY=true
		break
	fi
	sleep 10
done
if [[ "$CLUSTER_READY" != true ]]; then
	warn "Cluster health check timed out after 10 minutes."
	warn "The cluster may still be converging. Run 'talosctl health' to check."
else
	info "Cluster is healthy!"
fi

# ---------------------------------------------------------------------------
# Regenerate kubeconfig
# ---------------------------------------------------------------------------
talosctl kubeconfig "${CONFIG_DIR}/kubeconfig" --force 2>/dev/null || warn "Could not regenerate kubeconfig"

echo ""
info "Restore complete!"
info "  Run 'kubectl get nodes' to verify the cluster."
