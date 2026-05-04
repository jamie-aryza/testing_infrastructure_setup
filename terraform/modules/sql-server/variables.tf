variable "env" {}
variable "role" {}

variable "vpc_id" {}
variable "vpc_cidr" {}
variable "admin_cidr" {}

variable "windows_ami_id" {}
variable "subnet_id" {}
variable "iam_instance_profile" {}

variable "instance_type" {}

variable "root_volume_size" {}
variable "data_volume_size" {}
variable "log_volume_size" {}