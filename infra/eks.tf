# eks.tf — IAM roles, the EKS control plane, and the worker node group.

# ---------------------------------------------------------------------------
# IAM role for the EKS CONTROL PLANE
# Trust policy: only the EKS service may assume it.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# Security group for the cluster (control plane <-> nodes communication)
# ---------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS control plane SG"
  vpc_id      = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.cluster_name}-cluster-sg" }
}

# ---------------------------------------------------------------------------
# The EKS cluster itself
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.k8s_version

  # Enable access-entry API (required for aws_eks_access_entry to work).
  # API_AND_CONFIG_MAP keeps backward compat while enabling the modern path.
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  vpc_config {
    # Nodes go in private subnets; control plane ENIs span private + public.
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true # set false in a hardened prod build
  }

  # Send control-plane logs to CloudWatch — an SRE observability best practice.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# ---------------------------------------------------------------------------
# IAM role for the WORKER NODES (EC2 instances)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

# The three policies every EKS node needs:
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" # pod networking
}
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" # pull from ECR
}

# ---------------------------------------------------------------------------
# Managed node group — runs in PRIVATE subnets (no public IPs)
# ---------------------------------------------------------------------------
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = 3
    min_size     = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# ---------------------------------------------------------------------------
# EKS Access Entries — map IAM principals to Kubernetes permissions.
# This is the MODERN replacement for the aws-auth ConfigMap. Without this,
# the GitHub Actions role can describe the cluster but kubectl returns
# "Unauthorized" — the single most common EKS CI/CD failure.
# ---------------------------------------------------------------------------

# Ensure the cluster uses API-based access (not just the legacy ConfigMap).
# Note: set this in the aws_eks_cluster.main resource's access_config too if
# starting fresh. Shown here as a separate concern for clarity.

resource "aws_eks_access_entry" "gha" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.gha.arn
  type          = "STANDARD"
}

# Grant the GHA role cluster admin (demo-simple). In prod you'd scope this
# to a namespace with EKSEditPolicy instead of EKSClusterAdminPolicy.
resource "aws_eks_access_policy_association" "gha_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.gha.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.gha]
}
