# Security groups + IAM roles. Identity layer — EKS (eks.tf) and RDS (rds.tf)
# depend on these.

data "aws_caller_identity" "current" {}

# ==========================================================================
# SECURITY GROUPS
# A security group is a stateful virtual firewall attached to ENIs. "Stateful"
# means: if you allow an inbound connection, the return traffic is allowed
# automatically — you don't write a matching outbound rule. This matters
# below: we open INBOUND to RDS without needing a reverse rule.
# ==========================================================================

# --- Cluster security group -----------------------------------------------
# Attached to the EKS-managed network interfaces and the worker nodes. Egress
# fully open (nodes need to reach the internet via NAT + AWS APIs). Ingress
# is mostly managed by EKS itself; we keep this SG as the IDENTITY that other
# SGs reference. The SG itself is the "thing" RDS will trust.
resource "aws_security_group" "cluster" {
  name        = "${var.project}-cluster-sg"
  description = "EKS cluster and node security group"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow all outbound (image pulls, AWS APIs via NAT)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-cluster-sg" }
}

# --- RDS security group ---------------------------------------------------
# THE key security pattern. Inbound 5432 allowed ONLY from the cluster SG,
# referenced by SECURITY GROUP ID, not by CIDR. This means: "only ENIs
# wearing the cluster SG may reach Postgres." It survives subnet/IP changes
# and is far tighter than a CIDR allow. No egress rules needed — RDS only
# responds to inbound, and SGs are stateful so the response is auto-allowed.
resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "Postgres access from the EKS cluster only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from cluster nodes only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster.id]  # SG-to-SG, not CIDR
  }

  tags = { Name = "${var.project}-rds-sg" }
}

# ==========================================================================
# EKS SERVICE ROLES — what AWS permissions the cluster and nodes get.
# ==========================================================================

# --- EKS cluster role -----------------------------------------------------
# Assumed by the EKS control plane service. Lets EKS manage AWS resources on
# your behalf (ENIs, etc.). The trust policy says "eks.amazonaws.com may
# assume this role" — that's what AssumeRole + the service principal means.
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Node group role ------------------------------------------------------
# Assumed by the EC2 worker nodes. Needs three managed policies:
#   - WorkerNodePolicy: core node operations
#   - CNI_Policy: the VPC CNI plugin that wires pod networking into the VPC
#   - ECR ReadOnly: so nodes can PULL images from your ECR repo
resource "aws_iam_role" "eks_nodes" {
  name = "${var.project}-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ==========================================================================
# GITHUB OIDC — keyless CI/CD. The "wow" of this file.
# ==========================================================================
# Normally CI needs long-lived AWS access keys stored as secrets — a standing
# liability (leak = persistent access). Instead, we trust GitHub's OIDC
# identity provider. GitHub Actions mints a short-lived OIDC token describing
# the workflow (repo, branch, etc.); AWS verifies it against this provider and
# issues TEMPORARY credentials. No static keys anywhere. The only repo secret
# is a role ARN, which is useless without the matching OIDC trust.

# The OIDC provider: AWS will trust tokens issued by GitHub's Actions OIDC.
# The thumbprint pins GitHub's TLS cert; we fetch it dynamically with the tls
# provider rather than hardcoding (it can rotate).
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# --- Deployer role assumed by GitHub Actions ------------------------------
# The trust policy is the security boundary. It says: a GitHub OIDC token may
# assume this role ONLY IF its `sub` claim matches our repo AND the main
# branch. So a PR from a fork, or a push to another branch, CANNOT assume it.
# This is the "PRs don't deploy; only main deploys" rule enforced in IAM, not
# just in the workflow YAML.
resource "aws_iam_role" "github_deployer" {
  name = "${var.project}-github-deployer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # CHANGE THIS to your GitHub org/user + repo name.
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

# What the deployer can DO: push images to ECR and talk to EKS. Scoped, not
# admin. (ECR push perms + EKS describe so it can fetch a kubeconfig.)
resource "aws_iam_role_policy" "github_deployer" {
  name = "${var.project}-github-deployer-policy"
  role = aws_iam_role.github_deployer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = "*"
      },
      {
        Sid      = "EKSDescribe"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "*"
      }
    ]
  })
}