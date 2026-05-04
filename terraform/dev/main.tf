module "vpc" {
  source              = "../modules/vpc"
  env                 = var.env
  region              = var.region
  cidr                = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.3.0/24"
  private_subnet_cidr = "10.0.1.0/24"
}
