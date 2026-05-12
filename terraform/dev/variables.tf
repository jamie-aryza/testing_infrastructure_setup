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

variable "live_windows_ami_id" {
  description = "AMI ID for the live SQL host base Windows image."
  type        = string
  default     = "ami-0b08995d5950c62de" # Windows Server 2022 Base 
}

variable "test_windows_ami_id" {
  description = "AMI ID for the test SQL host base Windows image."
  type        = string
  default     = "ami-088b9d070a2d77f88" # Windows Server 2016 Base 
}
