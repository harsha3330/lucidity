variable "aws_account_id" {
  description = "AWS account ID this stack is allowed to run against."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}
