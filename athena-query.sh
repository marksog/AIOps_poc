#!/usr/bin/env bash
set -euo pipefail
SQL="$1"
QID=$(aws athena start-query-execution --region us-east-1 \
  --work-group aiops-poc-cloudtrail \
  --query-execution-context Database='aiops-poc_cloudtrail' \
  --query-string "$SQL" --query 'QueryExecutionId' --output text)
while true; do
  STATE=$(aws athena get-query-execution --region us-east-1 \
    --query-execution-id "$QID" --query 'QueryExecution.Status.State' --output text)
  [[ "$STATE" == "SUCCEEDED" || "$STATE" == "FAILED" || "$STATE" == "CANCELLED" ]] && break
  sleep 1
done
if [[ "$STATE" != "SUCCEEDED" ]]; then
  echo "Query $STATE:"
  aws athena get-query-execution --region us-east-1 --query-execution-id "$QID" \
    --query 'QueryExecution.Status.StateChangeReason' --output text
  exit 1
fi
# render each row as a tab-separated line, preserving row structure
aws athena get-query-results --region us-east-1 --query-execution-id "$QID" \
  --output json | python3 -c '
import json,sys
d=json.load(sys.stdin)
for row in d["ResultSet"]["Rows"]:
    print("\t".join(c.get("VarCharValue","") for c in row["Data"]))'
