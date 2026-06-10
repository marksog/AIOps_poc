# Postgres in the ISOLATED subnets, reachable only from the cluster SG.
# Password is generated, never written by a human, and stored in Secrets
# Manager — which Phase 5 reads to build the k8s Secret the pod consumes.

# --- DB subnet group ------------------------------------------------------
# RDS requires a "subnet group" telling it which subnets it may live in. We
# give it ONLY the isolated subnets — the ones whose route table has no
# internet path. So RDS is physically placed in the locked-down tier.
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = aws_subnet.isolated[*].id
  tags       = { Name = "${var.project}-db-subnet-group" }
}

# --- Generated password ---------------------------------------------------
# random_password generates a strong password at plan/apply time. No human
# ever sees or types it. NOTE: it DOES land in Terraform state in plaintext —
# which is exactly why the state bucket is encrypted + versioned + private.
# That's the honest tradeoff; the mitigation is securing state, which we did.
resource "random_password" "db" {
  length  = 24
  special = true
  # Exclude characters that break PostgreSQL connection URLs (@ : / etc.)
  # so the DATABASE_URL we build later doesn't need URL-encoding gymnastics.
  override_special = "!#%*_-+=" # safe punctuation only
}

# --- The RDS instance -----------------------------------------------------
resource "aws_db_instance" "main" {
  identifier     = "${var.project}-postgres"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro" # smallest/cheapest; fine for the demo

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true # encrypt at rest; cheap and expected

  db_name  = "checkout"
  username = "checkout_admin"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id] # the SG-to-SG locked one

  # publicly_accessible = false is the default but we state it: no public
  # endpoint, no internet path. Combined with isolated subnets = truly private.
  publicly_accessible = false

  # Lab hygiene: skip the final snapshot so teardown is clean and free, and
  # allow destroy. In PRODUCTION you'd want skip_final_snapshot=false and
  # deletion_protection=true — call that out in an interview.
  skip_final_snapshot = true
  deletion_protection = false

  # Single-AZ for cost. Production: multi_az = true for failover.
  multi_az = false

  tags = { Name = "${var.project}-postgres" }
}

# ==========================================================================
# SECRETS MANAGER — the vault that Phase 5 reads to build the k8s Secret.
# ==========================================================================
# We store a JSON blob with the connection bits. Phase 5's script pulls this,
# assembles a DATABASE_URL, and creates a k8s Secret. The bridge is:
#   Secrets Manager (AWS vault) -> script -> k8s Secret -> pod env DATABASE_URL
# The app never knows where the creds came from; it just reads DATABASE_URL.
resource "aws_secretsmanager_secret" "db" {
  name = "${var.project}/db-credentials"

  # recovery_window_in_days = 0 means a destroyed secret is deleted IMMEDIATELY
  # rather than held for 7-30 days. This is a LAB convenience: it avoids the
  # "secret name already exists, scheduled for deletion" collision when you
  # teardown and rebuild. In PRODUCTION you'd leave the default recovery window
  # so a fat-fingered delete is recoverable.
  recovery_window_in_days = 0

  tags = { Name = "${var.project}-db-credentials" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = aws_db_instance.main.username
    password = random_password.db.result
    host     = aws_db_instance.main.address # the RDS endpoint hostname
    port     = aws_db_instance.main.port
    dbname   = aws_db_instance.main.db_name
  })
}

# EKS managed node groups egress under the EKS-MANAGED cluster security group
# (auto-created by EKS), NOT the custom cluster SG we authored. So the RDS
# rule trusting our custom SG never matches real pod traffic. Trust the
# managed cluster SG too — this is the SG the packets actually wear.
resource "aws_security_group_rule" "rds_from_eks_managed" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description              = "Postgres from EKS-managed cluster SG (real pod egress identity)"
}