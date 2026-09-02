variable "aws_account_id" {
  description = "AWS account ID this stack is allowed to run against."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "name" {
  description = "Base name for the cluster and related resources."
  type        = string
  default     = "lucidity"
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.34"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint (your IP/32)."
  type        = list(string)
}

variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to assume the CI role via OIDC."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDRs, one per AZ. Nodes and pods live here (VPC CNI: one IP per pod)."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDRs, one per AZ. Only the NAT gateways and load balancers live here."
  type        = list(string)
  default     = ["10.0.2.0/24", "10.0.3.0/24"]
}

variable "github_repo_id_qualified" {
  description = "ID-qualified repo subject (owner@user_id/repo@repo_id) from: gh api repos/<owner>/<repo>/actions/oidc/customization/sub"
  type        = string
  default     = "harsha3330@105787285/lucidity@1354988421"
}
