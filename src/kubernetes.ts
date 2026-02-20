import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import { kubeconfig } from "./talos";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const config = new pulumi.Config();
const cloudflareTunnelToken = config.getSecret("cloudflareTunnelToken");
const githubAppId = config.getSecret("githubAppId");
const githubAppInstallationId = config.getSecret("githubAppInstallationId");
const githubAppPrivateKey = config.getSecret("githubAppPrivateKey");
const newRelicLicenseKey = config.getSecret("newRelicLicenseKey");

// ---------------------------------------------------------------------------
// Kubernetes Provider (initialized from Talos-generated kubeconfig)
// ---------------------------------------------------------------------------
export const k8sProvider = new k8s.Provider("k8s-provider", {
	kubeconfig: kubeconfig.kubeconfigRaw,
});

// ---------------------------------------------------------------------------
// Namespaces
// ---------------------------------------------------------------------------
const cloudflaredNs = new k8s.core.v1.Namespace(
	"cloudflared-ns",
	{
		metadata: { name: "cloudflared" },
	},
	{ provider: k8sProvider },
);

const argocdNs = new k8s.core.v1.Namespace(
	"argocd-ns",
	{
		metadata: { name: "argocd" },
	},
	{ provider: k8sProvider },
);

// ---------------------------------------------------------------------------
// Cloudflare Tunnel token secret
// ---------------------------------------------------------------------------
if (cloudflareTunnelToken) {
	new k8s.core.v1.Secret(
		"cloudflared-token",
		{
			metadata: {
				name: "cloudflared-token",
				namespace: "cloudflared",
			},
			stringData: {
				token: cloudflareTunnelToken,
			},
		},
		{ provider: k8sProvider, dependsOn: [cloudflaredNs] },
	);
}

// ---------------------------------------------------------------------------
// ArgoCD GitHub App repo credential secret
// ---------------------------------------------------------------------------
if (githubAppId && githubAppInstallationId && githubAppPrivateKey) {
	new k8s.core.v1.Secret(
		"argocd-repo-github-app",
		{
			metadata: {
				name: "argocd-repo-github-app",
				namespace: "argocd",
				labels: {
					"argocd.argoproj.io/secret-type": "repo-creds",
				},
			},
			stringData: {
				type: "git",
				url: "https://github.com/faulty-technology",
				githubAppID: githubAppId,
				githubAppInstallationID: githubAppInstallationId,
				githubAppPrivateKey: githubAppPrivateKey,
			},
		},
		{ provider: k8sProvider, dependsOn: [argocdNs] },
	);
}

// ---------------------------------------------------------------------------
// New Relic — namespace + license key secret
// nri-infrastructure DaemonSet requires privileged PSS.
// Two secrets needed: namespace-scoped, so one per consumer (nri-bundle + Fluent Bit).
// ---------------------------------------------------------------------------
const newrelicNs = new k8s.core.v1.Namespace(
	"newrelic-ns",
	{
		metadata: {
			name: "newrelic",
			labels: { "pod-security.kubernetes.io/enforce": "privileged" },
		},
	},
	{ provider: k8sProvider },
);

// Logging namespace created here so the NR secret exists before Fluent Bit starts.
// ArgoCD's Fluent Bit app (managedNamespaceMetadata) will see the existing namespace.
const loggingNs = new k8s.core.v1.Namespace(
	"logging-ns",
	{
		metadata: {
			name: "logging",
			labels: { "pod-security.kubernetes.io/enforce": "privileged" },
		},
	},
	{ provider: k8sProvider },
);

if (newRelicLicenseKey) {
	new k8s.core.v1.Secret(
		"newrelic-license-key",
		{
			metadata: { name: "newrelic-license-key", namespace: "newrelic" },
			stringData: { licenseKey: newRelicLicenseKey },
		},
		{ provider: k8sProvider, dependsOn: [newrelicNs] },
	);

	new k8s.core.v1.Secret(
		"newrelic-license-key-logging",
		{
			metadata: { name: "newrelic-license-key", namespace: "logging" },
			stringData: { licenseKey: newRelicLicenseKey },
		},
		{ provider: k8sProvider, dependsOn: [loggingNs] },
	);
}

// ---------------------------------------------------------------------------
// ArgoCD Helm release
// ---------------------------------------------------------------------------
const argocd = new k8s.helm.v3.Release(
	"argocd",
	{
		name: "argocd",
		namespace: "argocd",
		chart: "argo-cd",
		repositoryOpts: {
			repo: "https://argoproj.github.io/argo-helm",
		},
		valueYamlFiles: [
			new pulumi.asset.FileAsset("manifests/argocd/argocd-values.yaml"),
		],
		// Dynamic values merged on top of the static values file.
		// Injects GitHub App credentials for the notifications controller.
		values:
			githubAppId && githubAppInstallationId && githubAppPrivateKey
				? {
						notifications: {
							secret: {
								items: {
									"github-privateKey": githubAppPrivateKey,
								},
							},
							notifiers: {
								"service.github": pulumi.interpolate`appID: ${githubAppId}\ninstallationID: ${githubAppInstallationId}\nprivateKey: $github-privateKey\n`,
							},
						},
					}
				: {},
		timeout: 300,
		waitForJobs: true,
	},
	{ provider: k8sProvider, dependsOn: [argocdNs] },
);

// ---------------------------------------------------------------------------
// Root App of Apps — tells ArgoCD to sync all workloads from Git.
// ArgoCD-ingress is NOT applied here because it uses Traefik's IngressRoute
// CRD which won't exist until ArgoCD syncs Traefik. Instead, create an
// ArgoCD Application for it so ArgoCD manages it (retries until CRD exists).
// ---------------------------------------------------------------------------
new k8s.yaml.ConfigFile(
	"argocd-root-app",
	{
		file: "manifests/argocd/root-app.yaml",
	},
	{ provider: k8sProvider, dependsOn: [argocd] },
);

// ---------------------------------------------------------------------------
// ArgoCD initial admin password (generated by the Helm chart on each install)
// kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
// ---------------------------------------------------------------------------
const argocdAdminSecret = k8s.core.v1.Secret.get(
	"argocd-initial-admin-secret",
	pulumi.interpolate`argocd/argocd-initial-admin-secret`,
	{ provider: k8sProvider, dependsOn: [argocd] },
);

export const argocdAdminPassword = argocdAdminSecret.data.apply(
	(data) => Buffer.from(data["password"], "base64").toString("utf-8"),
);
