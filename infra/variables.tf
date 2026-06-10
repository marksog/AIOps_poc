variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for all resources."
}

variable "project" {
  type        = string
  default     = "aiops-poc"
  description = "Name prefix for resources, for easy identification."
}

# Two AZs = high availability without over-provisioning. Subnets get spread
# across these. us-east-1a / us-east-1b are the safe, always-present AZs.
variable "azs" {
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
  description = "Availability Zones to spread subnets across."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "The VPC's address space. /16 = 65,536 addresses, plenty."
}

# Three tiers x two AZs = six subnets. Each /24 gives 251 usable IPs.
# The CIDR layout is intentional and readable:
#   10.0.0.x / 10.0.1.x   -> public  (one per AZ)
#   10.0.10.x / 10.0.11.x -> private (nodes)
#   10.0.20.x / 10.0.21.x -> isolated (db)
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "isolated_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "cluster_name" {
  type    = string
  default = "aiops-poc"
}

variable "cluster_version" {
  type        = string
  default     = "1.31"
  description = "EKS Kubernetes version."
}

variable "github_repo" {
  type        = string
  description = "GitHub repository in the format https://github.com/marksog/AIOps_poc"
}