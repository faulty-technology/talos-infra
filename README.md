# Talos Cluster — Phase 0 (Single Node)

Single Talos Linux node on AWS running both control plane and workloads.
ArgoCD manages all Kubernetes apps via App of Apps pattern. ~$31-34/mo.

## Quick Start

```bash
# 1. Install prerequisites (AWS CLI, talosctl, kubectl, helm)
chmod +x scripts/*.sh
./scripts/bootstrap-prerequisites.sh

# 2. Configure AWS credentials (if not done yet)
aws configure
#   Access Key ID:     <from IAM>
#   Secret Access Key: <from IAM>
#   Region:            us-east-1
#   Output:            json

# 3. Configure secrets (one-time)
npm install
source .env.local
pulumi stack init dev
pulumi config set --secret talos-cluster:allowedCidrs '["<your-ip>/32"]'
pulumi config set --secret talos-cluster:cloudflareTunnelToken <token>
pulumi config set --secret talos-cluster:githubAppId <id>
pulumi config set --secret talos-cluster:githubAppInstallationId <id>
# Multi-line PEM — pipe via stdin with trailing --
cat <path/to/github-app.pem> | pulumi config set --secret talos-cluster:githubAppPrivateKey --

# 4. Deploy everything (AWS + Talos + K8s secrets + ArgoCD)
pulumi up

# 5. Verify
export KUBECONFIG=.talos/kubeconfig
kubectl get nodes
kubectl get pods -A
```

## What Gets Created

### AWS Resources (via Pulumi)

- VPC with 1 public subnet (us-east-1a)
- Internet gateway + route table
- Security group (ports 6443 + 50000 inbound, restricted to configured CIDR; all outbound)
- IAM role with EBS CSI + CloudWatch Logs permissions
- S3 bucket for etcd backups (versioned, encrypted, 30-day lifecycle)
- t3a.medium EC2 instance running Talos Linux
- Elastic IP (stable address across restarts)

### Kubernetes Components (via ArgoCD App of Apps)

- **ArgoCD** — GitOps controller, manages all apps below
- **argocd-ingress** — Traefik IngressRoute for ArgoCD UI
- **EBS CSI driver** — gp3 StorageClass (default, encrypted)
- **Fluent Bit** — log shipping to CloudWatch
- **Metrics Server** — enables `kubectl top`
- **Traefik** — ingress controller (ClusterIP, no LB needed)
- **cloudflared** — Cloudflare Tunnel connector
- **StorageClass** — gp3 encrypted default
- **test-app** — sample deployment for validation
- **project-apps** — AppProject constraining app workloads
- **app-repo-discovery** — ApplicationSet that auto-generates Applications from a list of external repos (each repo provides its own config in `.argocd/`)

## Day 2 Operations

### Access the cluster

```bash
source .env.local
# or manually:
export KUBECONFIG=.talos/kubeconfig
export TALOSCONFIG=.talos/talosconfig
```

### Talos dashboard

```bash
talosctl dashboard
```

### ArgoCD UI

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:443
# https://localhost:8080
# Username: admin
# Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Onboard a new app repo

The `app-repo-discovery` ApplicationSet uses a list-based generator. Each app repo provides its own ArgoCD config in a `.argocd/` directory. To add a new repo, append an entry to the list in `manifests/argocd/apps/app-repo-discovery.yaml`:

```yaml
generators:
  - list:
      elements:
        - repo: hello-k8s
          branch: main
        - repo: my-new-app # <-- add here
          branch: main
```

ArgoCD will auto-create an Application pointing to `https://github.com/faulty-technology/<repo>.git` and sync from its `.argocd/` directory. See [hello-k8s/.argocd/](https://github.com/faulty-technology/hello-k8s/tree/main/.argocd) for a working example.

### etcd backup

```bash
./scripts/ops-etcd-backup.sh           # Local snapshot
./scripts/ops-etcd-backup.sh --s3      # Also upload to S3
```

### Stop (save money) / Start the node

```bash
# Stop
aws ec2 stop-instances --instance-ids $(pulumi stack output nodeInstanceId)

# Start
aws ec2 start-instances --instance-ids $(pulumi stack output nodeInstanceId)
# EIP stays attached — same public IP after restart
```

### Tear down everything

```bash
pulumi destroy
```

## Security Notes

- Talos PKI is stored in Pulumi state — back up your Pulumi state backend
- If Pulumi state is lost, the cluster is **unrecoverable** (Talos has no SSH, no SSM, no console)
- `.talos/` contains client credentials — treat like SSH keys
- Security group restricts inbound to `allowedCidrs` in Pulumi config — set this to your IP

## Cost Breakdown

| Component                | Monthly     |
| ------------------------ | ----------- |
| t3a.medium (on-demand)   | ~$28        |
| EBS gp3 root (20GB)      | ~$1.60      |
| EBS gp3 PVCs (est. 20GB) | ~$1.60      |
| Elastic IP (attached)    | $0          |
| Cloudflare Tunnel        | $0          |
| **Total**                | **~$31-34** |

Note: Elastic IPs are free when attached to a running instance.
Stopped instances with attached EIPs cost ~$0.005/hr ($3.60/mo).

## Architecture Diagrams

### System Overview

High-level view of the running system — what talks to what.

```mermaid
graph TB
    subgraph Internet
        Public([Public Users])
        Admin([Operator])
        GH[GitHub<br/>faulty-technology/*]
    end

    subgraph "Cloudflare"
        CFEdge[Cloudflare Edge]
        CFAccess[Access Policies<br/>Zero Trust]
    end

    subgraph "AWS — us-east-1a"
        EIP[Elastic IP]

        subgraph "VPC 10.0.0.0/16"
            subgraph "EC2 — Talos Linux (t3a.medium)"
                subgraph "Kubernetes (single node)"
                    ArgoCD[ArgoCD]
                    Traefik[Traefik<br/>Ingress Controller]
                    Cloudflared[cloudflared<br/>Tunnel Connector]
                    FluentBit[Fluent Bit]
                    EBSCSI[EBS CSI Driver]
                    Apps[App Workloads]
                end
            end
        end

        S3[(S3<br/>etcd backups)]
        CW[(CloudWatch<br/>Logs)]
        EBS[(EBS gp3<br/>Volumes)]
    end

    Public -- HTTPS --> CFEdge
    Admin -- HTTPS --> CFEdge
    CFEdge --> CFAccess
    CFAccess -- "public routes" --> Cloudflared
    CFAccess -. "protected routes<br/>(e.g. ArgoCD UI)" .-> Cloudflared
    Cloudflared -. "outbound tunnel<br/>(no inbound ports)" .-> CFEdge
    Cloudflared --> Traefik
    Traefik --> Apps
    Admin -- "kubectl :6443<br/>talosctl :50000" --> EIP
    EIP --> Kubernetes
    ArgoCD -- "sync from Git" --> GH
    FluentBit --> CW
    Apps -. PVCs .-> EBSCSI --> EBS
    Kubernetes -. "etcd snapshots" .-> S3
```

### Pulumi Deployment Pipeline

What `pulumi up` does — the sequential steps from zero to running cluster.

```mermaid
flowchart LR
    subgraph "1 — AWS"
        VPC[VPC + Subnet<br/>+ IGW + SG]
        IAM[IAM Role<br/>+ Policies]
        EC2[EC2 Instance<br/>+ EIP]
        S3B[S3 Bucket]
    end

    subgraph "2 — Talos"
        Secrets[Generate PKI<br/>Secrets]
        Config[Derive Machine<br/>Config]
        Apply[Apply Config<br/>to Node]
        Boot[Bootstrap<br/>etcd]
        Health[Wait for<br/>Cluster Health]
        Kube[Retrieve<br/>Kubeconfig]
    end

    subgraph "3 — Kubernetes"
        NS[Create<br/>Namespaces]
        K8Sec[Create Secrets<br/>cloudflared + GitHub App]
        Helm[Install ArgoCD<br/>via Helm]
        Root[Apply Root<br/>App of Apps]
    end

    subgraph "4 — Files"
        TC[Write<br/>talosconfig]
        KC[Write<br/>kubeconfig]
    end

    VPC --> EC2
    IAM --> EC2
    EC2 --> Secrets
    Secrets --> Config --> Apply --> Boot --> Health --> Kube
    Kube --> NS --> K8Sec --> Helm --> Root
    Kube --> TC
    Kube --> KC
```

### ArgoCD GitOps Flow

How ArgoCD manages cluster workloads after initial deployment.

```mermaid
flowchart TB
    subgraph "talos-infra repo"
        RootApp["root Application<br/>(manifests/argocd/apps/)"]
        AppDefs["Application manifests<br/>ebs-csi, traefik, cloudflared,<br/>fluent-bit, metrics-server,<br/>storageclass, test-app, ..."]
        AppSet["ApplicationSet<br/>app-repo-discovery"]
    end

    subgraph "App repos (faulty-technology/*)"
        Repo1["hello-k8s/.argocd/"]
        Repo2["subnet-cheat-sheet/.argocd/"]
        Repo3["belowthefold-rocks/.argocd/"]
    end

    subgraph "Kubernetes Cluster"
        ArgoCD[ArgoCD]
        InfraApps["Infrastructure Apps<br/>(Traefik, EBS CSI, Fluent Bit, ...)"]
        UserApps["App Workloads<br/>(hello-k8s, subnet-cheat-sheet, ...)"]
    end

    Pulumi["pulumi up"] -- "installs ArgoCD +<br/>applies root app" --> ArgoCD
    ArgoCD -- "syncs" --> RootApp
    RootApp -- "contains" --> AppDefs
    RootApp -- "contains" --> AppSet
    AppDefs -- "synced by ArgoCD" --> InfraApps
    AppSet -- "generates Applications<br/>from list" --> Repo1 & Repo2 & Repo3
    Repo1 & Repo2 & Repo3 -- "synced by ArgoCD" --> UserApps
```
