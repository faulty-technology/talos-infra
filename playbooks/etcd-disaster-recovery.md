# etcd Disaster Recovery Playbook

## Taking Snapshots

### Local snapshot only

```bash
source .env.local
./scripts/ops-etcd-backup.sh
```

Creates a timestamped snapshot at `.talos/snapshots/etcd-snapshot-<timestamp>.db`. Local snapshots older than 7 days are automatically pruned.

### Snapshot + save to S3

```bash
./scripts/ops-etcd-backup.sh --save-to-s3
```

Takes a fresh snapshot and immediately uploads it to the S3 backup bucket.

### Save a specific snapshot to S3

```bash
./scripts/ops-etcd-backup.sh --save-to-s3 .talos/snapshots/etcd-snapshot-20260208T120000Z.db
```

Takes a fresh local snapshot (always), then uploads the **specified** file to S3. Useful for uploading a known-good snapshot from an earlier point in time.

## Finding Snapshots

### Local snapshots

```bash
ls -lh .talos/snapshots/etcd-snapshot-*.db
```

### S3 snapshots

```bash
# Listed automatically at the end of any backup run, or manually:
source .env.local
aws s3 ls "s3://$(pulumi stack output etcdBackupBucketName)/snapshots/"
```

The backup script prints available S3 snapshots after each run.

## Restoring from a Snapshot

**This is a destructive operation.** The node is reset, etcd is wiped, and all data written after the snapshot is lost. The script will prompt for confirmation.

### From a local file

```bash
./scripts/ops-etcd-restore.sh .talos/snapshots/etcd-snapshot-20260208T120000Z.db
```

### From S3

```bash
./scripts/ops-etcd-restore.sh s3://talos-homelab-etcd-backups/snapshots/etcd-snapshot-20260208T120000Z.db
```

### What the restore script does

1. Downloads from S3 if an `s3://` URI is provided
2. Prompts for confirmation (type `yes`)
3. Resets the node (`talosctl reset --graceful=false --reboot`)
4. Waits for maintenance mode (~1-5 min)
5. Re-applies `controlplane.yaml` + `patch-single-node.yaml` via `talosctl apply-config --insecure`
6. Bootstraps etcd from the snapshot (`talosctl bootstrap --recover-from=<file>`)
7. Waits for cluster health
8. Regenerates kubeconfig

After restore, verify with:

```bash
kubectl get nodes
kubectl get pods -A
talosctl health
```

## Recovery Scenarios

### Node dies, EBS root volume lost

1. `pulumi up` — recreates EC2, reattaches EIP, reapplies Talos config, bootstraps etcd
2. `./scripts/ops-etcd-restore.sh s3://.../<latest-snapshot>.db`
3. EBS data volumes reattach automatically (PVCs rebind)

### etcd corruption, node still running

1. `./scripts/ops-etcd-restore.sh .talos/snapshots/etcd-snapshot-<known-good>.db`
2. Script handles the reset + restore automatically

### Full disaster (everything gone)

Requires two things preserved offsite:
- Pulumi state (contains Talos PKI, stack config, cloud state — **unrecoverable if lost**)
- Latest etcd snapshot (in S3)

Steps:
1. `pulumi up` — recreates all AWS infra + Talos bootstrap + K8s secrets + ArgoCD
2. `./scripts/ops-etcd-restore.sh s3://.../<snapshot>.db`

### `.talos/` folder deleted (configs lost, cluster still running)

Everything in `.talos/` is written by Pulumi — no etcd restore needed.

1. `pulumi up` — rewrites `.talos/talosconfig` and `.talos/kubeconfig`

No data is lost — the cluster state is untouched.

## What's Backed Up (and What's Not)

| Data | In etcd snapshot? | Recovery path |
|------|:-:|---|
| K8s resources (Deployments, Services, ConfigMaps, Secrets) | Yes | Restore snapshot |
| PVC metadata | Yes | Restore snapshot |
| PVC data (EBS volume contents) | No | EBS volumes persist independently; PVCs rebind |
| Talos machine config | No | Re-derived by Pulumi from state |
| Talos PKI (secrets) | No | Stored in Pulumi state |

## What Must Be Backed Up Offsite

These items **cannot** be regenerated and must be preserved:

1. **Pulumi state** — contains Talos PKI, stack config, cloud state. Cluster is unrecoverable without it.
2. **etcd snapshots** — in S3 (automated via `ops-etcd-backup.sh --save-to-s3`).
