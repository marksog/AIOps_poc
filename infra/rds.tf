# rds.tf — managed Postgres, reachable ONLY from the EKS nodes.

# ---------------------------------------------------------------------------
# DB subnet group — RDS must live across >=2 AZs. We use the isolated db subnets.
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.cluster_name}-db-subnets"
  subnet_ids = aws_subnet.db[*].id
  tags       = { Name = "${var.cluster_name}-db-subnets" }
}

# ---------------------------------------------------------------------------
# Security group for RDS.
# KEY DESIGN: ingress is allowed ONLY from the node group's security group,
# referenced by ID — not by CIDR. If node IPs change, the rule still holds.
# This is the "least privilege networking" point interviewers look for.
# ---------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-rds-sg"
  description = "Allow Postgres only from EKS nodes"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.cluster_name}-rds-sg" }
  # Ingress is defined as a separate rule below so it can reference the
  # EKS cluster security group cleanly (no circular dependency).
}

# Allow Postgres ONLY from the EKS cluster security group. Every managed-node-group
# node is a member of this SG, so this transitively allows your pods — and nothing else.
resource "aws_security_group_rule" "rds_from_cluster" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

# ---------------------------------------------------------------------------
# Generate a strong DB password and store it in Secrets Manager.
# Never hardcode DB passwords in Terraform — this keeps it out of state-as-plaintext
# as much as possible and gives you rotation later.
# ---------------------------------------------------------------------------
resource "random_password" "db" {
  length  = 24
  special = false # avoids URL-encoding headaches in the connection string
}

resource "aws_secretsmanager_secret" "db" {
  name = "${var.cluster_name}-db-credentials"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    dbname   = var.db_name
  })
}

# ---------------------------------------------------------------------------
# The Postgres instance
# ---------------------------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier             = "${var.cluster_name}-pg"
  engine                 = "postgres"
  engine_version         = "16.4"
  instance_class         = "db.t3.micro" # cheapest; fine for demo
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = var.db_name
  username               = var.db_username
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = false # set true for prod HA (doubles cost)
  publicly_accessible    = false # NEVER true for a real DB
  skip_final_snapshot    = true  # demo only; prod should snapshot
  storage_encrypted      = true

  tags = { Name = "${var.cluster_name}-pg" }
}
