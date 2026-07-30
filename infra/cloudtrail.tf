# CloudTrail = AWS's audit log of every API call in the account. AWS writes
# it automatically; we just need somewhere to put it (S3) and a way to query
# it (Athena). This is the control-plane "what changed" evidence source that
# lets Sentinel correlate an alert with the action that caused it.

data "aws_caller_identity" "ct" {}

# --- S3 bucket to hold the trail logs -------------------------------------
# CloudTrail delivers compressed JSON log files here, partitioned by date.
# Same pattern as Loki chunks in object storage: cheap storage, query on demand.
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project}-cloudtrail-${data.aws_caller_identity.ct.account_id}"
  force_destroy = true   # lab: let destroy empty+remove it. Prod: false.
  tags = { Name = "${var.project}-cloudtrail" }
}

# Block all public access — audit logs are sensitive (they show your API
# patterns, principals, source IPs). Never public.
resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudTrail needs explicit S3 bucket-policy permission to write here. This
# is the exact policy AWS requires — two statements: check the bucket ACL,
# and put objects under the account's path with bucket-owner-full-control.
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.ct.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

# --- The trail itself -----------------------------------------------------
resource "aws_cloudtrail" "main" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true   # capture IAM/STS (global) events too
  is_multi_region_trail         = true   # catch events from any region
  enable_log_file_validation    = true   # tamper-evidence: signed digests

  # Depend on the bucket policy — the trail fails to create if it can't write.
  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = { Name = "${var.project}-trail" }
}

output "cloudtrail_bucket" {
  value = aws_s3_bucket.cloudtrail.id
}

# --- Athena: SQL over the CloudTrail logs in S3 ---------------------------
# Athena is serverless SQL over S3 — conceptually the same as querying Loki
# chunks or a Splunk index sitting in object storage. You pay per byte
# SCANNED, so partitioning (below) is what keeps cost near zero.

# Results bucket — SEPARATE from the log bucket so query output never gets
# re-scanned as if it were log data.
resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.project}-athena-results-${data.aws_caller_identity.ct.account_id}"
  force_destroy = true
  tags = { Name = "${var.project}-athena-results" }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# A "workgroup" is Athena's unit of config + cost isolation. It pins where
# results go and lets you cap bytes scanned per query — a real cost guardrail.
resource "aws_athena_workgroup" "cloudtrail" {
  name = "${var.project}-cloudtrail"

  configuration {
    enforce_workgroup_configuration = true
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/results/"
    }
    # Safety cap: kill any query that would scan more than 1 GB. In a lab this
    # should never trigger; it's a guardrail against a runaway unpartitioned scan.
    bytes_scanned_cutoff_per_query = 1073741824
  }

  tags = { Name = "${var.project}-cloudtrail-wg" }
}

# A Glue database is just a logical namespace for Athena tables.
resource "aws_glue_catalog_database" "cloudtrail" {
  name = "${var.project}_cloudtrail"
}

output "athena_workgroup" {
  value = aws_athena_workgroup.cloudtrail.name
}

output "athena_database" {
  value = aws_glue_catalog_database.cloudtrail.name
}