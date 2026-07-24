# Separate ECR repo for the Sentinel agent image. Distinct from checkout-svc
# because they're different applications with different lifecycles.

resource "aws_ecr_repository" "sentinel" {
  name = "${var.project}/sentinel"

  image_scanning_configuration {
    scan_on_push = true          # CVE scan on every push, same as checkout-svc
  }

  image_tag_mutability = "IMMUTABLE"   # SHA tags are frozen, reproducible

  force_delete = true            # lab: let destroy remove it with images

  tags = { Name = "${var.project}-sentinel" }
}

resource "aws_ecr_lifecycle_policy" "sentinel" {
  repository = aws_ecr_repository.sentinel.name
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

output "sentinel_ecr_url" {
  value = aws_ecr_repository.sentinel.repository_url
}