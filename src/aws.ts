import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const config = new pulumi.Config();
export const clusterName = config.get("clusterName") || "talos-homelab";
const instanceType = config.get("instanceType") || "t3a.medium";
const rootVolumeSize = config.getNumber("rootVolumeSize") || 20;
const allowedCidrs = config.getObject<string[]>("allowedCidrs") || [
	"0.0.0.0/0",
];

export const tags = { Project: clusterName, ManagedBy: "pulumi" };

// ---------------------------------------------------------------------------
// Talos AMI Lookup (official Sidero Labs images)
// ---------------------------------------------------------------------------
const talosAmi = aws.ec2.getAmiOutput({
	mostRecent: true,
	owners: ["540036508848"], // Sidero Labs
	filters: [
		{ name: "name", values: ["talos-v1.12*"] },
		{ name: "architecture", values: ["x86_64"] },
		{ name: "virtualization-type", values: ["hvm"] },
	],
});

// ---------------------------------------------------------------------------
// VPC + Networking (single AZ, public subnet)
// ---------------------------------------------------------------------------
const vpc = new aws.ec2.Vpc("vpc", {
	cidrBlock: "10.0.0.0/16",
	enableDnsSupport: true,
	enableDnsHostnames: true,
	tags: { ...tags, Name: `${clusterName}-vpc` },
});

const subnet = new aws.ec2.Subnet("subnet", {
	vpcId: vpc.id,
	cidrBlock: "10.0.1.0/24",
	availabilityZone: "us-east-1a",
	mapPublicIpOnLaunch: true,
	tags: { ...tags, Name: `${clusterName}-public` },
});

const igw = new aws.ec2.InternetGateway("igw", {
	vpcId: vpc.id,
	tags: { ...tags, Name: `${clusterName}-igw` },
});

const routeTable = new aws.ec2.RouteTable("route-table", {
	vpcId: vpc.id,
	routes: [{ cidrBlock: "0.0.0.0/0", gatewayId: igw.id }],
	tags: { ...tags, Name: `${clusterName}-rt` },
});

new aws.ec2.RouteTableAssociation("rt-assoc", {
	subnetId: subnet.id,
	routeTableId: routeTable.id,
});

// ---------------------------------------------------------------------------
// Security Group
// ---------------------------------------------------------------------------
const sg = new aws.ec2.SecurityGroup("sg", {
	name: `${clusterName}-sg`,
	vpcId: vpc.id,
	description: "Talos single-node cluster",
	ingress: [
		{
			description: "Talos API (talosctl)",
			protocol: "tcp",
			fromPort: 50000,
			toPort: 50000,
			cidrBlocks: allowedCidrs,
		},
		{
			description: "Kubernetes API",
			protocol: "tcp",
			fromPort: 6443,
			toPort: 6443,
			cidrBlocks: allowedCidrs,
		},
	],
	egress: [
		{
			description: "All outbound",
			protocol: "-1",
			fromPort: 0,
			toPort: 0,
			cidrBlocks: ["0.0.0.0/0"],
		},
	],
	tags: { ...tags, Name: `${clusterName}-sg` },
});

// ---------------------------------------------------------------------------
// IAM Role — EC2 instance profile with EBS CSI permissions
// ---------------------------------------------------------------------------
const instanceRole = new aws.iam.Role("instance-role", {
	assumeRolePolicy: JSON.stringify({
		Version: "2012-10-17",
		Statement: [
			{
				Effect: "Allow",
				Principal: { Service: "ec2.amazonaws.com" },
				Action: "sts:AssumeRole",
			},
		],
	}),
	tags: { ...tags, Name: `${clusterName}-instance-role` },
});

// EBS CSI driver needs these permissions to manage volumes
new aws.iam.RolePolicy("ebs-csi-policy", {
	role: instanceRole.id,
	policy: JSON.stringify({
		Version: "2012-10-17",
		Statement: [
			{
				Effect: "Allow",
				Action: [
					"ec2:CreateSnapshot",
					"ec2:AttachVolume",
					"ec2:DetachVolume",
					"ec2:ModifyVolume",
					"ec2:DescribeAvailabilityZones",
					"ec2:DescribeInstances",
					"ec2:DescribeSnapshots",
					"ec2:DescribeTags",
					"ec2:DescribeVolumes",
					"ec2:DescribeVolumesModifications",
					"ec2:CreateVolume",
					"ec2:DeleteVolume",
					"ec2:DeleteSnapshot",
					"ec2:CreateTags",
					"ec2:DeleteTags",
				],
				Resource: "*",
			},
		],
	}),
});

const instanceProfile = new aws.iam.InstanceProfile("instance-profile", {
	role: instanceRole.name,
	tags: { ...tags, Name: `${clusterName}-instance-profile` },
});

// ---------------------------------------------------------------------------
// Elastic IP (stable address across stop/start cycles)
// ---------------------------------------------------------------------------
export const eip = new aws.ec2.Eip("eip", {
	domain: "vpc",
	tags: { ...tags, Name: `${clusterName}-eip` },
});

// ---------------------------------------------------------------------------
// EC2 Instance — Single Talos node (control plane + worker)
// ---------------------------------------------------------------------------
export const instance = new aws.ec2.Instance("talos-node", {
	ami: talosAmi.id,
	instanceType: instanceType,
	subnetId: subnet.id,
	vpcSecurityGroupIds: [sg.id],
	iamInstanceProfile: instanceProfile.name,
	rootBlockDevice: {
		volumeSize: rootVolumeSize,
		volumeType: "gp3",
		deleteOnTermination: true,
		tags: { ...tags, Name: `${clusterName}-root` },
	},
	tags: { ...tags, Name: `${clusterName}-node` },
	metadataOptions: {
		httpTokens: "required", // IMDSv2 only
		httpEndpoint: "enabled",
	},
});

// Associate the Elastic IP after instance creation
new aws.ec2.EipAssociation("eip-assoc", {
	instanceId: instance.id,
	allocationId: eip.id,
});

// ---------------------------------------------------------------------------
// S3 Bucket — etcd backup snapshots
// ---------------------------------------------------------------------------
const etcdBackupBucket = new aws.s3.BucketV2("etcd-backup-bucket", {
	bucket: `${clusterName}-etcd-backups`,
	tags: { ...tags, Name: `${clusterName}-etcd-backups` },
});

new aws.s3.BucketVersioningV2("etcd-backup-versioning", {
	bucket: etcdBackupBucket.id,
	versioningConfiguration: { status: "Enabled" },
});

new aws.s3.BucketLifecycleConfigurationV2("etcd-backup-lifecycle", {
	bucket: etcdBackupBucket.id,
	rules: [
		{
			id: "expire-old-backups",
			status: "Enabled",
			expiration: { days: 30 },
			noncurrentVersionExpiration: { noncurrentDays: 7 },
		},
	],
});

new aws.s3.BucketServerSideEncryptionConfigurationV2("etcd-backup-sse", {
	bucket: etcdBackupBucket.id,
	rules: [
		{
			applyServerSideEncryptionByDefault: {
				sseAlgorithm: "AES256",
			},
		},
	],
});

new aws.s3.BucketPublicAccessBlock("etcd-backup-public-access", {
	bucket: etcdBackupBucket.id,
	blockPublicAcls: true,
	blockPublicPolicy: true,
	ignorePublicAcls: true,
	restrictPublicBuckets: true,
});

// IAM policy: allow EC2 instance to read/write etcd backups
new aws.iam.RolePolicy("etcd-backup-policy", {
	role: instanceRole.id,
	policy: pulumi.interpolate`{
		"Version": "2012-10-17",
		"Statement": [{
			"Effect": "Allow",
			"Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
			"Resource": [
				"arn:aws:s3:::${etcdBackupBucket.bucket}",
				"arn:aws:s3:::${etcdBackupBucket.bucket}/*"
			]
		}]
	}`,
});

// IAM policy: allow Fluent Bit to ship logs to CloudWatch
new aws.iam.RolePolicy("cloudwatch-logs-policy", {
	role: instanceRole.id,
	policy: JSON.stringify({
		Version: "2012-10-17",
		Statement: [
			{
				Effect: "Allow",
				Action: [
					"logs:CreateLogGroup",
					"logs:CreateLogStream",
					"logs:PutLogEvents",
					"logs:DescribeLogGroups",
					"logs:DescribeLogStreams",
				],
				Resource: "arn:aws:logs:us-east-1:*:log-group:/talos-homelab/*",
			},
		],
	}),
});

// ---------------------------------------------------------------------------
// Exported values for downstream modules
// ---------------------------------------------------------------------------
export const vpcId = vpc.id;
export const subnetId = subnet.id;
export const securityGroupId = sg.id;
export const talosAmiId = talosAmi.id;
export const talosAmiName = talosAmi.name;
export const etcdBackupBucketName = etcdBackupBucket.bucket;
