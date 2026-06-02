# cicd.tf — keyless GitHub Actions auth via OIDC + the ECR repository.

variable "github_repo" {
  type        = string
  description = "owner/repo, e.g. mark/aiops-control-plane"
  # Set this to your actual repo before applying.
}

# ---------------------------------------------------------------------------
# ECR repository for the checkout-svc image
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "checkout" {
  name                 = "checkout-svc"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true # free vulnerability scanning — an SRE/security plus
  }
}

# Lifecycle policy: keep only the last 10 images so ECR doesn't grow forever.
resource "aws_ecr_lifecycle_policy" "checkout" {
  repository = aws_ecr_repository.checkout.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# OIDC identity provider for GitHub Actions
# This registers GitHub as a trusted token issuer in your AWS account.
# ---------------------------------------------------------------------------
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# ---------------------------------------------------------------------------
# The role GitHub Actions assumes. Trust policy locks it to YOUR repo + branch.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "gha_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    # Audience must be sts.amazonaws.com
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # THE LOCK: only this repo, only the main branch.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha" {
  name               = "${var.cluster_name}-gha-deployer"
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
}

# Permissions the pipeline needs: push to ECR + describe the cluster for kubectl.
data "aws_iam_policy_document" "gha_perms" {
  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken cannot be resource-scoped
  }
  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
      "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.checkout.arn]
  }
  statement {
    sid       = "EKSDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.main.arn]
  }
}

resource "aws_iam_role_policy" "gha" {
  name   = "gha-deploy-perms"
  role   = aws_iam_role.gha.id
  policy = data.aws_iam_policy_document.gha_perms.json
}

output "gha_role_arn" {
  value       = aws_iam_role.gha.arn
  description = "Put this in the GitHub workflow as role-to-assume"
}

output "ecr_repo_url" {
  value = aws_ecr_repository.checkout.repository_url
}
