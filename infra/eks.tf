# EKS control plane + a managed node group in PRIVATE subnets, using the
# modern API access-entry auth mode (not the legacy aws-auth configmap).

# --- Control plane --------------------------------------------------------
# The EKS-managed Kubernetes API server + etcd. We place its ENIs across ALL
# subnets (private for nodes, public for any internet-facing LB path). The
# control plane endpoint is public here for convenience (you'll kubectl from
# your laptop), but private access is also on so in-cluster traffic stays
# internal. Production often goes private-only + a bastion/VPN.
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = concat(
      aws_subnet.private[*].id,
      aws_subnet.public[*].id,
    )
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # CRITICAL: authentication_mode = API means cluster access is governed by
  # EKS ACCESS ENTRIES (an AWS API), NOT the old aws-auth ConfigMap. The
  # configmap approach was error-prone: one bad YAML edit could lock everyone
  # out, and it lived inside the cluster. Access entries are IAM-native,
  # auditable, and can't brick your access the same way. bootstrap_..._admin
  # gives the IAM identity that CREATES the cluster admin rights, so you
  # aren't locked out on day one.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # The cluster role's policy attachment must exist BEFORE the cluster, or
  # creation fails for lack of permissions. Explicit ordering.
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = { Name = var.cluster_name }
}

# --- Managed node group — workers in PRIVATE subnets ----------------------
# subnet_ids = private only. Nodes get NO public IPs; they reach out via the
# NAT. Nothing on the internet can initiate a connection to them. This is the
# single biggest "is this person serious about security" signal in the build.
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  # t3.medium x desired 2. scaling_config lets you scale to ZERO when you
  # pause (cost discipline — set desired=0 to stop paying for nodes without
  # destroying the cluster).
  instance_types = ["t3.medium"]
  scaling_config {
    desired_size = 3      # was 2 — third node so Vault's anti-affinity
                          # can place one Raft member per node
    min_size     = 1
    max_size     = 3
  }

  # Roll nodes one at a time on updates, never fully unavailable.
  update_config {
    max_unavailable = 1
  }

  # Node group needs the node role's policies attached first.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  tags = { Name = "${var.project}-nodes" }
}

# ==========================================================================
# OIDC PROVIDER FOR IRSA — pods assume IAM roles without node-wide keys.
# ==========================================================================
# IRSA (IAM Roles for Service Accounts) lets a specific k8s ServiceAccount
# assume a specific IAM role, scoped to one pod identity — instead of every
# pod inheriting the node's role. This is the AWS-side foundation for
# least-privilege pod identity, which Sentinel (Phase 8) will lean on: the
# agent's ServiceAccount gets exactly the AWS perms it needs, nothing more.
#
# The cluster issues OIDC tokens; this provider lets AWS IAM trust them.
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# ==========================================================================
# EBS CSI DRIVER — required for any PersistentVolumeClaim to actually bind.
# The default `gp2` StorageClass points at the IN-TREE provisioner
# (kubernetes.io/aws-ebs), which was REMOVED in k8s 1.23+. Without this
# addon, PVCs sit Pending forever with no clear error. Needed for Vault's
# Raft storage (3 replicas = 3 PVCs).
# ==========================================================================

# Strip the https:// prefix from the OIDC issuer URL — IAM condition keys
# use the bare host+path form, not a URL.
locals {
  oidc_provider_bare = replace(
    aws_iam_openid_connect_provider.eks.url, "https://", ""
  )
}

# The role the CSI CONTROLLER assumes. Same IRSA mechanism as the GitHub
# deployer role: OIDC token -> trust policy checks the `sub` claim -> temp
# credentials. The sub is scoped to ONE service account in ONE namespace,
# so only the CSI controller can assume it.
resource "aws_iam_role" "ebs_csi" {
  name = "${var.project}-ebs-csi-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_bare}:aud" = "sts.amazonaws.com"
          "${local.oidc_provider_bare}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

# AWS-managed policy: create/attach/detach/delete volumes, snapshots, tags.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# The managed addon. AWS installs and maintains the controller + node
# DaemonSet; we just supply the identity it runs as.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  # If a conflicting config already exists, let the addon win rather than
  # failing the apply.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}