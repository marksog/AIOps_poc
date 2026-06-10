# --- VPC ------------------------------------------------------------------
# enable_dns_hostnames + enable_dns_support are REQUIRED for EKS: nodes and
# the API server resolve each other (and AWS service endpoints) by DNS.
# Without these, the cluster's internal name resolution breaks.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

# --- Internet Gateway -----------------------------------------------------
# The VPC's door to the internet. Only the PUBLIC route table points at it.
# Attaching an IGW doesn't make anything public by itself — a subnet is only
# public if its route table has a 0.0.0.0/0 route THROUGH this IGW.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# ==========================================================================
# SUBNETS — three tiers, two AZs each. count + element() pattern keeps it DRY.
# ==========================================================================

# --- Public subnets (one per AZ) ------------------------------------------
# Hold the NAT gateway and, later, the load balancer ENIs. map_public_ip
# auto-assigns public IPs to things launched here. The EKS tags let the
# AWS Load Balancer Controller discover these as the place to put PUBLIC
# (internet-facing) load balancers.
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.project}-public-${count.index}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# --- Private subnets (one per AZ) — EKS WORKER NODES live here -------------
# No public IPs. Nodes reach OUT to the internet via NAT (to pull images,
# call AWS APIs) but nothing reaches IN from the internet. The internal-elb
# tag marks these for INTERNAL load balancers.
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name                                        = "${var.project}-private-${count.index}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# --- Isolated subnets (one per AZ) — RDS lives here -----------------------
# The most locked-down tier. Their route table has NO internet route at all,
# not even through NAT. RDS here can ONLY be reached from inside the VPC.
resource "aws_subnet" "isolated" {
  count             = length(var.isolated_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.isolated_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.project}-isolated-${count.index}" }
}

# ==========================================================================
# NAT GATEWAY — lets private nodes reach the internet OUTBOUND only.
# ==========================================================================
# A NAT gateway needs a static public IP (Elastic IP) and must SIT in a
# PUBLIC subnet. Private subnets route their 0.0.0.0/0 at this NAT.
#
# COST NOTE: the NAT gateway is the single most expensive always-on piece
# here (~$1/day + data). We use ONE NAT (in AZ-a) shared by both private
# subnets — cheaper, at the cost of cross-AZ data charges and a single point
# of failure. Production would run one NAT per AZ. Stating that tradeoff is
# the senior move.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id  # NAT sits in the first public subnet
  tags          = { Name = "${var.project}-nat" }

  # Explicit dependency: the IGW must exist before the NAT, because the NAT's
  # own internet path goes through it. Terraform usually infers this, but
  # making it explicit documents the ordering.
  depends_on = [aws_internet_gateway.main]
}

# ==========================================================================
# ROUTE TABLES — this is where the three-tier ISOLATION actually happens.
# Subnets are identical until a route table gives them a path. The routes
# ARE the security boundary.
# ==========================================================================

# --- Public route table: 0.0.0.0/0 -> IGW (direct internet) ---------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private route table: 0.0.0.0/0 -> NAT (outbound-only internet) --------
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.project}-rt-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Isolated route table: NO 0.0.0.0/0 route AT ALL ----------------------
# This is the whole point of the isolated tier. With only the implicit local
# route (VPC-internal traffic), RDS can talk to nodes inside the VPC but has
# ZERO path to or from the internet. Most locked-down tier, by construction.
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.main.id
  # Intentionally no route block. Only the implicit local route exists.
  tags = { Name = "${var.project}-rt-isolated" }
}

resource "aws_route_table_association" "isolated" {
  count          = length(aws_subnet.isolated)
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}