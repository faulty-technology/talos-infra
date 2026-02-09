#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# ops-etcd-backup.sh
# Takes an etcd snapshot and optionally uploads it to S3.
# Usage: ./scripts/ops-etcd-backup.sh [--save-to-s3 [snapshot-file]]
# ---------------------------------------------------------------------------

SCRIPT_DIR=$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")
source "${SCRIPT_DIR}/utils.sh"

UPLOAD=false
UPLOAD_FILE=""
if [[ "${1:-}" == "--save-to-s3" ]]; then
	UPLOAD=true
	UPLOAD_FILE="${2:-}"
fi

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
command -v talosctl >/dev/null 2>&1 || error "talosctl not found. Run ./scripts/bootstrap-prerequisites.sh"

if [[ -z "${TALOSCONFIG:-}" ]]; then
	export TALOSCONFIG="${CONFIG_DIR}/talosconfig"
fi
[[ -f "$TALOSCONFIG" ]] || error "TALOSCONFIG not found at ${TALOSCONFIG}. Has the cluster been bootstrapped?"

# ---------------------------------------------------------------------------
# Take etcd snapshot
# ---------------------------------------------------------------------------
SNAPSHOT_DIR="${CONFIG_DIR}/snapshots"
mkdir -p "$SNAPSHOT_DIR"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAPSHOT_FILE="${SNAPSHOT_DIR}/etcd-snapshot-${TIMESTAMP}.db"

info "Taking etcd snapshot..."
talosctl etcd snapshot "$SNAPSHOT_FILE" || error "etcd snapshot failed"

SNAPSHOT_SIZE="$(stat --printf='%s' "$SNAPSHOT_FILE" 2>/dev/null || stat -f '%z' "$SNAPSHOT_FILE")"
info "Snapshot saved: ${SNAPSHOT_FILE} ($(numfmt --to=iec "$SNAPSHOT_SIZE" 2>/dev/null || echo "${SNAPSHOT_SIZE} bytes"))"

# ---------------------------------------------------------------------------
# Save to S3 (optional)
# ---------------------------------------------------------------------------
if [[ "$UPLOAD" == true ]]; then
	command -v aws >/dev/null 2>&1 || error "AWS CLI not found. Run ./scripts/bootstrap-prerequisites.sh"

	cd "$PROJECT_DIR"
	BUCKET="$(pulumi stack output etcdBackupBucketName 2>/dev/null)" || error "Could not get etcdBackupBucketName from Pulumi. Did you run 'pulumi up'?"

	SAVE_TARGET="${UPLOAD_FILE:-$SNAPSHOT_FILE}"
	[[ -f "$SAVE_TARGET" ]] || error "Snapshot file not found: ${SAVE_TARGET}"

	S3_KEY="snapshots/$(basename "$SAVE_TARGET")"
	info "Saving to s3://${BUCKET}/${S3_KEY}..."
	aws s3 cp "$SAVE_TARGET" "s3://${BUCKET}/${S3_KEY}" || error "S3 upload failed"
	info "Upload complete: s3://${BUCKET}/${S3_KEY}"
fi

# ---------------------------------------------------------------------------
# Prune local snapshots older than 7 days
# ---------------------------------------------------------------------------
PRUNED=0
while IFS= read -r -d '' old_snap; do
	rm -f "$old_snap"
	PRUNED=$((PRUNED + 1))
done < <(find "$SNAPSHOT_DIR" -name 'etcd-snapshot-*.db' -mtime +7 -print0 2>/dev/null)

if [[ "$PRUNED" -gt 0 ]]; then
	info "Pruned ${PRUNED} local snapshot(s) older than 7 days"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "Backup complete!"
info "  Local: ${SNAPSHOT_FILE}"
if [[ "$UPLOAD" == true ]]; then
	info "  S3:    s3://${BUCKET}/${S3_KEY}"

	echo ""
	info "Available S3 snapshots:"
	aws s3 ls "s3://${BUCKET}/snapshots/" 2>/dev/null | while read -r line; do
		echo "         ${line}"
	done
fi
