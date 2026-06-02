#!/usr/bin/env bash
# Reads RDS credentials from Secrets Manager and creates the k8s Secret
# that the deployment consumes as DATABASE_URL. Run once after infra apply.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-aiops-eks}"
REGION="${AWS_REGION:-us-east-1}"

# Pull the secret JSON created by Terraform
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "${CLUSTER_NAME}-db-credentials" \
  --region "$REGION" --query SecretString --output text)

DB_USER=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['username'])")
DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")
DB_NAME=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['dbname'])")

# Get the RDS endpoint (terraform output, or pass DB_HOST in env)
DB_HOST="${DB_HOST:?Set DB_HOST to the RDS endpoint (terraform output db_endpoint)}"

# Build the async SQLAlchemy URL the app expects
DATABASE_URL="postgresql+psycopg://${DB_USER}:${DB_PASS}@${DB_HOST}:5432/${DB_NAME}"

kubectl create secret generic checkout-db \
  --from-literal=database_url="$DATABASE_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret 'checkout-db' created/updated."
