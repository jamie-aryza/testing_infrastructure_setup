variable "env" {
  description = "Environment name (dev, test)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR block"
  type        = string
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR block"
  type        = string
}
