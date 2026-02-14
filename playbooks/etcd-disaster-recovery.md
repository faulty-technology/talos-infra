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

1. `pulumi up` — creates new EC2, reattaches EIP
2. Regenerate configs: `talosctl gen config --with-secrets secrets/secrets.yaml ...`
3. `./scripts/ops-etcd-restore.sh s3://.../<latest-snapshot>.db`
4. EBS data volumes reattach automatically (PVCs rebind)

### etcd corruption, node still running

1. `./scripts/ops-etcd-restore.sh .talos/snapshots/etcd-snapshot-<known-good>.db`
2. Script handles the reset + restore automatically

### Full disaster (everything gone)

Requires three things preserved offsite:
- `secrets/secrets.yaml` (master PKI — **unrecoverable if lost**)
- Pulumi state (stack config + cloud state)
- Latest etcd snapshot (in S3)

Steps:
1. `pulumi up` — recreate all AWS infra
2. `talosctl gen config --with-secrets secrets/secrets.yaml` — regenerate machine configs
3. `./scripts/ops-etcd-restore.sh s3://.../<snapshot>.db`

### `.talos/` folder deleted (configs lost, cluster still running)

Everything in `.talos/` is regenerable — no etcd restore needed.

1. Re-run `./scripts/bootstrap-cluster.sh` — detects the node is already configured, regenerates `controlplane.yaml`, `talosconfig`, `kubeconfig`, and `patch-single-node.yaml` from `secrets/secrets.yaml` + Pulumi outputs
2. Generate a new GitHub App private key from the App settings page (GitHub > Settings > Developer settings > GitHub Apps > argocd-talos > Generate a private key), save to `.talos/github-app-private-key.pem`
3. Re-run `./scripts/bootstrap-secrets.sh` to recreate K8s secrets (cloudflared-token, GitHub App creds)
4. Re-run `./scripts/bootstrap-install-argocd.sh`

No data is lost — the cluster state is untouched.

## What's Backed Up (and What's Not)

| Data | In etcd snapshot? | Recovery path |
|------|:-:|---|
| K8s resources (Deployments, Services, ConfigMaps, Secrets) | Yes | Restore snapshot |
| PVC metadata | Yes | Restore snapshot |
| PVC data (EBS volume contents) | No | EBS volumes persist independently; PVCs rebind |
| Talos machine config | No | Re-derive from `secrets.yaml` |
| `secrets.yaml` | No | Must be backed up separately |
| GitHub App private key | No | Generate new key from GitHub App settings page |

## What Must Be Backed Up Offsite

These items **cannot** be regenerated and must be preserved:

1. **`secrets/secrets.yaml`** — master PKI. Cluster is unrecoverable without it.
2. **Pulumi state** — stack config + cloud state (Pulumi Cloud or local backend).
3. **etcd snapshots** — in S3 (automated via `ops-etcd-backup.sh --save-to-s3`).
4. **GitHub App private key** (optional) — can be regenerated from GitHub, but backing it up avoids re-running the ArgoCD bootstrap.
