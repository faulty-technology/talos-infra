# GitHub App Setup

One-time guide for creating and configuring the GitHub App used by ArgoCD for repository access and deployment status notifications.

## 1. Create the GitHub App

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **Name**: something descriptive (e.g., `talos-argocd`)
   - **Homepage URL**: `https://argocd.faulty.technology` (or any valid URL)
   - **Webhook**: uncheck "Active" (not needed)

## 2. Configure Permissions

Under **Repository permissions**, set:

| Permission | Access | Used by |
|---|---|---|
| Contents | Read-only | ArgoCD repo sync (pulling manifests from Git) |
| Metadata | Read-only | Required (auto-selected) |
| Deployments | Read and write | ArgoCD Notifications (posting deployment statuses) |

No organization or account permissions are needed.

## 3. Install the App

1. After creating the app, go to **Install App** in the left sidebar
2. Install it on the `faulty-technology` organization
3. Choose either **All repositories** or select specific repos that ArgoCD manages

> **Note:** If you later add new permissions to an existing app, the org installation enters a pending state and the new permissions won't be active until an org owner approves the update. Check **GitHub → faulty-technology org → Settings → GitHub Apps** for a pending approval banner. Deployments silently fail with no error in ArgoCD logs until this is accepted.

## 4. Generate a Private Key

1. Go to the app's settings page → **General** → **Private keys**
2. Click **Generate a private key**
3. Save the downloaded `.pem` file securely

## 5. Collect the Credentials

You need three values for Pulumi config:

| Value | Where to find it |
|---|---|
| **App ID** | App settings page → General → App ID (numeric) |
| **Installation ID** | Go to the app's installations page, click the org, and grab the numeric ID from the URL: `github.com/organizations/faulty-technology/settings/installations/<this-number>` |
| **Private Key** | The `.pem` file downloaded in step 4 |

## 6. Set Pulumi Config

```bash
source .env.local

pulumi config set --secret talos-cluster:githubAppId <app-id>
pulumi config set --secret talos-cluster:githubAppInstallationId <installation-id>
cat <path/to/github-app.pem> | pulumi config set --secret talos-cluster:githubAppPrivateKey --
```

## 7. Verify After Deployment

After `pulumi up`, confirm ArgoCD can access repos and notifications are working:

```bash
# ArgoCD should sync apps from GitHub
kubectl get applications -n argocd

# Notifications controller should be running
kubectl get pods -n argocd | grep notifications

# Check notification controller logs for GitHub service initialization
kubectl logs -n argocd deploy/argocd-notifications-controller | head -20
```

Deployment statuses appear on GitHub repos after the next sync event (push a commit or manually sync an app in ArgoCD).
