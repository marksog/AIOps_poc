# Private container registry for checkout-svc images. GitHub Actions pushes
# here (keyless, via the OIDC deployer role); nodes pull from here (via the
# node role's ECR-readonly policy). Both permission sides already exist in
# iam.tf — this is the repo they target.

resource "aws_ecr_repository" "checkout" {
  name = "${var.project}/checkout-svc"

  # Scan images for known CVEs automatically on every push. Cheap, and it's
  # your security background showing: vulnerabilities get flagged at the
  # registry before they ever reach the cluster. A genuine supply-chain control.
  image_scanning_configuration {
    scan_on_push = true
  }

  # IMMUTABLE tags: once a tag (e.g. a git SHA) is pushed, it can't be
  # overwritten. This guarantees that "image tagged abc123" ALWAYS means the
  # exact same bytes — critical for reproducible deploys and rollbacks. You
  # can never accidentally (or maliciously) repoint a tag at different code.
  image_tag_mutability = "IMMUTABLE"

  # Lab hygiene: force_delete lets `terraform destroy` remove the repo even if
  # it still holds images. In production you'd leave this false to avoid
  # nuking images that running workloads depend on.
  force_delete = true

  tags = { Name = "${var.project}-checkout-svc" }
}

# --- Lifecycle policy: keep the registry from growing forever -------------
# Every push adds an image. Without cleanup you'd accumulate hundreds of old
# SHAs. This keeps the 10 most recent and expires the rest — basic cost and
# hygiene discipline.
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