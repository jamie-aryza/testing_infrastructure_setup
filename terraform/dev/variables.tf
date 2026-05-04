variable "env" {
  description = "Environment name (e.g. dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region where resources are deployed"
  type        = string
  default     = "eu-west-2"
}

variable "admin_cidr" {
  description = "CIDR block allowed to RDP into SQL Server EC2s (e.g. your home IP as a /32). Set this in terraform.tfvars."
  type        = string
}
