# values (ARNs, endpoints, names) out of Terraform without digging in state.

output "cluster_name" {
  value       = aws_eks_cluster.main.name
  description = "For: aws eks update-kubeconfig --name <this>"
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "region" {
  value = var.region
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.checkout.repository_url
  description = "The image push/pull target, e.g. <acct>.dkr.ecr.us-east-1.amazonaws.com/aiops-poc/checkout-svc"
}

output "github_deployer_role_arn" {
  value       = aws_iam_role.github_deployer.arn
  description = "Put this in the GitHub repo as secret AWS_DEPLOY_ROLE_ARN (Phase 4)."
}

output "db_secret_name" {
  value       = aws_secretsmanager_secret.db.name
  description = "Secrets Manager secret Phase 5's script reads to build the k8s Secret."
}

output "rds_endpoint" {
  value     = aws_db_instance.main.address
  sensitive = true
}