import {
	eip,
	instance,
	vpcId,
	subnetId,
	securityGroupId,
	talosAmiId,
	talosAmiName,
	etcdBackupBucketName,
} from "./src/aws";

// Talos bootstrap (secrets → config → apply → bootstrap → kubeconfig)
import "./src/talos";

// Kubernetes secrets + ArgoCD
import { argocdAdminPassword } from "./src/kubernetes";

// Write talosconfig + kubeconfig to .talos/ for CLI access
import "./src/files";

// ---------------------------------------------------------------------------
// Stack Outputs
// ---------------------------------------------------------------------------
export const nodePublicIp = eip.publicIp;
export const nodePrivateIp = instance.privateIp;
export const nodeInstanceId = instance.id;
export {
	vpcId,
	subnetId,
	securityGroupId,
	talosAmiId,
	talosAmiName,
	etcdBackupBucketName,
};
export const region = "us-east-1";
export const availabilityZone = "us-east-1a";
export { argocdAdminPassword };
