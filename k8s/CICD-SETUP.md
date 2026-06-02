# CI/CD Setup — GitHub Actions → ECR → EKS (keyless via OIDC)

## One-time setup order
1. **Apply infra** (adds OIDC provider, GHA role, ECR repo). Set your repo first:
   ```bash
   cd ../project1-infra
   terraform apply -var="github_repo=YOUR_GH_USER/YOUR_REPO"
   terraform output gha_role_arn   # copy this
   terraform output ecr_repo_url
   ```

2. **Add GitHub repo secrets** (Settings → Secrets and variables → Actions):
   - `AWS_DEPLOY_ROLE_ARN` = the `gha_role_arn` output
   - (Docker Hub path only) `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`

3. **Create the DB secret in the cluster** (one time, after infra is up):
   ```bash
   cd ../checkout-svc
   export DB_HOST=$(cd ../project1-infra && terraform output -raw db_endpoint)
   ./k8s/create-db-secret.sh
   ```

4. **Push to main** → the workflow builds, pushes to ECR, deploys to EKS.

## Why OIDC (your interview soundbite)
No long-lived AWS keys stored in GitHub. GitHub presents a signed identity
token; the IAM trust policy only accepts it from `repo:YOUR_REPO:ref:refs/heads/main`.
Compromised repo secrets can't leak credentials because there are none to leak.

## Common failure → fix
- `Unauthorized` on kubectl  → EKS access entry missing (we added aws_eks_access_entry.gha)
- `Not authorized to perform sts:AssumeRoleWithWebIdentity` → sub claim mismatch;
   check the trust policy repo path matches exactly (case-sensitive)
- `id-token` error → workflow missing `permissions: id-token: write`
