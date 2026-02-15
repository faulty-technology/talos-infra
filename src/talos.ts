import * as pulumi from "@pulumi/pulumi";
import * as talos from "@pulumiverse/talos";
import { instance, eip, clusterName } from "./aws";

// ---------------------------------------------------------------------------
// Talos Secrets (root of all PKI)
// ---------------------------------------------------------------------------
const secrets = new talos.machine.Secrets("talos-secrets", {
	talosVersion: "v1.12",
});

// ---------------------------------------------------------------------------
// Single-node config patch
// ---------------------------------------------------------------------------
// Allow scheduling on control plane (single-node cluster) and configure
// certSANs with EIP, AWS time server, and KubePrism.
const configPatch = pulumi.interpolate`
cluster:
  allowSchedulingOnControlPlanes: true
machine:
  certSANs:
    - ${eip.publicIp}
  time:
    servers:
      - 169.254.169.123
  features:
    kubePrism:
      enabled: true
      port: 7445
`;

// ---------------------------------------------------------------------------
// Generate machine configuration
// ---------------------------------------------------------------------------
const machineConfig = talos.machine.getConfigurationOutput({
	clusterName: clusterName,
	clusterEndpoint: pulumi.interpolate`https://${eip.publicIp}:6443`,
	machineSecrets: secrets.machineSecrets,
	machineType: "controlplane",
	configPatches: [configPatch],
	docs: false,
	examples: false,
});

// ---------------------------------------------------------------------------
// Apply configuration to the node
// ---------------------------------------------------------------------------
// endpoint = EIP (public, what we connect TO)
// node = private IP (what the node recognizes as itself)
const configApply = new talos.machine.ConfigurationApply("talos-config-apply", {
	clientConfiguration: secrets.clientConfiguration,
	machineConfigurationInput: machineConfig.machineConfiguration,
	endpoint: eip.publicIp,
	node: instance.privateIp,
	// onDestroy not needed for full teardown — EC2 termination wipes the node.
	// Only useful when removing individual nodes from a multi-node cluster that
	// keeps running (graceful drains workloads to surviving nodes before reset).
	// onDestroy: { reset: true, graceful: true },
});

// ---------------------------------------------------------------------------
// Bootstrap etcd
// ---------------------------------------------------------------------------
const bootstrap = new talos.machine.Bootstrap(
	"talos-bootstrap",
	{
		clientConfiguration: secrets.clientConfiguration,
		endpoint: eip.publicIp,
		node: instance.privateIp,
	},
	{ dependsOn: [configApply], customTimeouts: { create: "10m" } },
);

// ---------------------------------------------------------------------------
// Wait for cluster health (K8s API, etcd, kubelet all ready)
// ---------------------------------------------------------------------------
const health = talos.cluster.getHealthOutput(
	{
		clientConfiguration: secrets.clientConfiguration,
		controlPlaneNodes: [instance.privateIp],
		endpoints: [eip.publicIp],
	},
	{ dependsOn: [bootstrap] },
);

// ---------------------------------------------------------------------------
// Retrieve kubeconfig from the running cluster
// ---------------------------------------------------------------------------
export const kubeconfig = new talos.cluster.Kubeconfig(
	"talos-kubeconfig",
	{
		clientConfiguration: secrets.clientConfiguration,
		endpoint: health.endpoints[0],
		node: instance.privateIp,
	},
	{ dependsOn: [bootstrap] },
);

// ---------------------------------------------------------------------------
// Generate talosconfig for CLI access
// ---------------------------------------------------------------------------
export const talosconfig = talos.client.getConfigurationOutput({
	clusterName: clusterName,
	clientConfiguration: secrets.clientConfiguration,
	endpoints: [eip.publicIp],
	nodes: [instance.privateIp],
});
