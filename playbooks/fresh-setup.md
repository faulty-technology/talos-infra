# Fresh Cluster Setup

End-to-end guide for standing up the Talos Kubernetes cluster from scratch.

## 1. Prerequisites

Install required tools:

```bash
./scripts/bootstrap-prerequisites.sh
```

This installs: `talosctl`, `kubectl`, `helm`, AWS CLI (if missing).

Ensure you have:
- AWS credentials configured (`aws sts get-caller-identity` should work)
- `.env.local` with `PULUMI_CONFIG_PASSPHRASE` set
- Node.js + npm installed

## 2. Deploy AWS Infrastructure

```bash
source .env.local
npm install
npm run up
```

This creates: VPC, subnet, security group, IAM role, EIP, and EC2 instance running Talos. Note the EIP from the Pulumi output — you'll need it for verification.

## 3. Bootstrap the Cluster

```bash
./scripts/bootstrap-cluster.sh
```

This script:
1. Generates `secrets/secrets.yaml` (master PKI — **back this up immediately**)
2. Derives machine config + talosconfig
3. Waits for the node to reach maintenance mode
4. Applies config and bootstraps etcd
5. Waits for the Kubernetes API to become available
6. Generates kubeconfig

## 4. Create Kubernetes Secrets

```bash
./scripts/bootstrap-secrets.sh
```

Creates secrets that ArgoCD-managed apps depend on:
- **cloudflared-token** in `cloudflared` namespace (from `CLOUDFLARE_TUNNEL_TOKEN` env var or Pulumi config)
- **argocd-repo-github-app** in `argocd` namespace (org-level `repo-creds` credential template for GitHub App)
- **argocd-ghcr-oci** in `argocd` namespace (optional — only needed if OCI Helm charts in GHCR are private)

Required env vars:
- `GITHUB_APP_ID` — numeric App ID
- `GITHUB_APP_INSTALLATION_ID` — numeric Installation ID
- `GITHUB_APP_PRIVATE_KEY_FILE` — path to the `.pem` file (defaults to `.talos/github-app-private-key.pem`)

Optional env vars (only for private GHCR charts):
- `GHCR_USERNAME` — GitHub username
- `GHCR_TOKEN` — PAT with `read:packages` scope

## 5. Install ArgoCD

```bash
./scripts/bootstrap-install-argocd.sh
```

Installs ArgoCD via Helm and applies the root App of Apps. ArgoCD then syncs all workloads (EBS CSI, Metrics Server, Traefik, StorageClass, cloudflared, test-app).

## 6. Verify

```bash
export TALOSCONFIG=$(pwd)/.talos/talosconfig
export KUBECONFIG=$(pwd)/.talos/kubeconfig

# Node should be Ready
kubectl get nodes

# All ArgoCD apps should sync to Healthy
kubectl get applications -n argocd

# All pods running
kubectl get pods -A

# Talos API accessible
talosctl version

# Full cluster health (etcd + k8s + nodes)
talosctl health
```

## 7. Post-Setup

### Back up secrets.yaml

`secrets/secrets.yaml` is the root of all cluster PKI. If lost, the cluster is **unrecoverable**. Copy it somewhere safe (password manager, encrypted cloud storage) immediately.

### Take an initial etcd snapshot

```bash
./scripts/ops-etcd-backup.sh --save-to-s3
```

### Configure Cloudflare Tunnel

If not already configured, set the `cloudflareTunnelToken` in Pulumi config:

```bash
pulumi config set --secret cloudflareTunnelToken <token>
npm run up
```

## 8. Teardown

To destroy all AWS resources:

```bash
source .env.local
npm run destroy
```

This removes: EC2 instance, EIP, VPC, subnet, security group, IAM role, S3 bucket. EBS data volumes with `Retain` policy may persist and need manual cleanup.

Local files (`.talos/`, `secrets/`) are not deleted — keep them if you plan to recreate the cluster with the same PKI.
