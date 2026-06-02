# Discover available AZs in the region so we don't hardcode them.
data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true # required for EKS + RDS DNS resolution
  enable_dns_hostnames = true # required so RDS gets a resolvable endpoint
  tags = { Name = "${var.cluster_name}-vpc" }
}

# ---------------------------------------------------------------------------
# Subnets: 2 public, 2 private (nodes), 2 db (isolated)
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.0.0.0/24, 10.0.1.0/24
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.cluster_name}-public-${count.index}"
    # These tags tell the AWS Load Balancer Controller this subnet is for public LBs.
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.cluster_name}"     = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10) # 10.0.10.0/24, 10.0.11.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "${var.cluster_name}-private-${count.index}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 20) # 10.0.20.0/24, 10.0.21.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = { Name = "${var.cluster_name}-db-${count.index}" }
}

# ---------------------------------------------------------------------------
# Internet Gateway — public subnets' door to the internet
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# ---------------------------------------------------------------------------
# NAT Gateway — lets PRIVATE subnets reach the internet OUTBOUND only.
# One NAT in one public subnet (cost-saving; prod would use one per AZ).
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.cluster_name}-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------
# Public: default route to the Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.cluster_name}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private: default route to the NAT Gateway (egress only)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.cluster_name}-rt-private" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# DB: NO default route. Fully isolated. Only local VPC traffic works.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-rt-db" }
}

resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}
