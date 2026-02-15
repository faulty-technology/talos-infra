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

## 2. Configure Pulumi Secrets

Set the required secret config values (one-time per stack):

```bash
source .env.local

# Required
pulumi config set --secret talos-cluster:allowedCidrs '["<your-ip>/32"]'
pulumi config set --secret talos-cluster:cloudflareTunnelToken <token>
pulumi config set --secret talos-cluster:githubAppId <id>
pulumi config set --secret talos-cluster:githubAppInstallationId <id>
# Multi-line PEM — pipe via stdin with trailing --
cat <path/to/github-app.pem> | pulumi config set --secret talos-cluster:githubAppPrivateKey --
```

## 3. Deploy Everything

```bash
source .env.local
npm install
npm run up
```

A single `pulumi up` does everything:

1. Creates AWS infrastructure (VPC, subnet, SG, IAM, EIP, EC2, S3)
2. Generates Talos PKI and machine configuration
3. Applies config to the node and bootstraps etcd
4. Retrieves kubeconfig from the running cluster
5. Creates K8s secrets (cloudflared-token, argocd-repo-github-app)
6. Installs ArgoCD via Helm
7. Applies ArgoCD ingress route and root App of Apps
8. Writes `.talos/talosconfig` and `.talos/kubeconfig` for CLI access

ArgoCD then syncs all workloads (EBS CSI, Metrics Server, Traefik, StorageClass, cloudflared, test-app).

## 4. Verify

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

# ArgoCD admin password (also available as a Pulumi stack output)
pulumi stack output argocdAdminPassword --show-secrets
# Or via kubectl:
# kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## 5. Post-Setup

### Back up Pulumi state

Talos PKI is stored in Pulumi state. Losing the state = unrecoverable cluster. Ensure your Pulumi state backend is backed up.

### Take an initial etcd snapshot

```bash
./scripts/ops-etcd-backup.sh --save-to-s3
```

### Configure Cloudflare Tunnel

If not already configured, add DNS CNAME records for your Cloudflare Tunnel:

- `argocd.faulty.technology CNAME <tunnel-id>.cfargotunnel.com` (proxied)
- `test-talos.faulty.technology CNAME <tunnel-id>.cfargotunnel.com` (proxied)

## 6. Teardown

To destroy all resources:

```bash
source .env.local
npm run destroy
```

This:

- Terminates the EC2 instance (no graceful Talos reset — unnecessary for full teardown)
- Removes all AWS resources (VPC, subnet, SG, IAM, EIP, S3)
- EBS data volumes with `Retain` policy may persist and need manual cleanup

Local files (`.talos/`) are not deleted by Pulumi destroy.

## 7. Full Rebuild

To burn down and rebuild from scratch:

```bash
source .env.local
./scripts/ops-etcd-backup.sh --save-to-s3   # Back up first
npm run destroy                               # Tear down
npm run up                                    # Rebuild
```

ArgoCD will re-sync all workloads automatically. Application data on retained EBS volumes may need to be re-attached manually.
