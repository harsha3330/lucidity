variable "aws_account_id" {
  description = "AWS account ID this stack is allowed to run against."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name (from 01-infra)."
  type        = string
  default     = "lucidity"
}

variable "karpenter_chart_version" {
  type    = string
  default = "1.14.1"
}

variable "kube_prometheus_stack_version" {
  type    = string
  default = "88.6.2"
}

variable "lb_controller_chart_version" {
  type    = string
  default = "3.5.0"
}
