# variables.tf
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "aiops-eks"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# Kubernetes version — check the current EKS-supported versions before applying:
# https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
variable "k8s_version" {
  type    = string
  default = "1.31"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium" # 2 vCPU / 4GB — enough for the demo, cheap
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "db_username" {
  type    = string
  default = "checkout"
}

variable "db_name" {
  type    = string
  default = "checkoutdb"
}
