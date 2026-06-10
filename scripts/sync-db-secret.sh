#!/usr/bin/env bash
# scripts/sync-db-secret.sh
# Bridges AWS Secrets Manager -> Kubernetes Secret.
# Reads the DB creds Terraform stored, builds a DATABASE_URL, and creates
# (or updates) the k8s Secret `checkout-db` that the Deployment injects.
#
# Run this AFTER `terraform apply` and BEFORE the first deploy. Re-run any
# time the DB password rotates.

set -euo pipefail

SECRET_NAME="aiops-poc/db-credentials"
REGION="us-east-1"
K8S_SECRET="checkout-db"
NAMESPACE="default"

echo "Reading $SECRET_NAME from Secrets Manager..."
# Pull the JSON blob. --query SecretString returns the raw JSON we stored.
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$REGION" \
  --query SecretString \
  --output text)

# Parse fields with jq. (brew install jq if you don't have it.)
USERNAME=$(echo "$SECRET_JSON" | jq -r .username)
PASSWORD=$(echo "$SECRET_JSON" | jq -r .password)
HOST=$(echo "$SECRET_JSON" | jq -r .host)
PORT=$(echo "$SECRET_JSON" | jq -r .port)
DBNAME=$(echo "$SECRET_JSON" | jq -r .dbname)

# Assemble the async Postgres URL the app expects. Note the scheme:
# postgresql+asyncpg -> SQLAlchemy picks the asyncpg driver. Same code path
# as local sqlite+aiosqlite, different scheme. This is the cloud-agnostic
# property paying off.
DATABASE_URL="postgresql+asyncpg://${USERNAME}:${PASSWORD}@${HOST}:${PORT}/${DBNAME}"

echo "Creating/updating k8s Secret $K8S_SECRET in namespace $NAMESPACE..."
# --dry-run=client | apply is the idempotent create-or-update idiom: it
# renders the Secret object client-side then applies it, so re-running
# updates in place instead of erroring on "already exists".
kubectl create secret generic "$K8S_SECRET" \
  --namespace "$NAMESPACE" \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Done. Secret $K8S_SECRET is ready."