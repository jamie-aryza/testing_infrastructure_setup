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
  description = "CIDR block allowed to reach WinRM HTTPS on the SQL Server EC2s (e.g. your home IP as a /32). Set this in terraform.tfvars."
  type        = string
}

variable "automation_admin_username" {
  description = "Local Windows admin account created during first-boot bootstrap for WinRM automation."
  type        = string
  default     = "sqlautomation"
}

variable "automation_admin_password" {
  description = "Password for the local Windows automation admin account. Prefer setting via TF_VAR_automation_admin_password."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.automation_admin_password) >= 8 &&
      can(regex("[A-Z]", var.automation_admin_password)) &&
      can(regex("[a-z]", var.automation_admin_password)) &&
      can(regex("[0-9!@#$%^&*()_+=\\[\\]{}|;:,.<>?/~`^\\-]", var.automation_admin_password))
    )
    error_message = "Password must be at least 8 characters and contain uppercase, lowercase, and at least one digit or special character (Windows complexity requirement). Also ensure it does not contain 3 or more consecutive characters from the username — Windows silently rejects those passwords at account creation time."
  }
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
