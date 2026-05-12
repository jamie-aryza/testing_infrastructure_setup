module "vpc" {
  source              = "../modules/vpc"
  env                 = var.env
  region              = var.region
  cidr                = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.3.0/24"
  private_subnet_cidr = "10.0.1.0/24"
}

resource "aws_iam_role" "ssm" {
  name = "dev-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "ec2-ssm-profile"
  role = aws_iam_role.ssm.name
}

module "sql_live" {
  source = "../modules/sql-server"

  env        = var.env
  role       = "live"
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = module.vpc.vpc_cidr
  admin_cidr = var.admin_cidr
  subnet_id  = module.vpc.public_subnet_id

  windows_ami_id = "ami-0b08995d5950c62de" # Windows Server 2022 Base 
  iam_instance_profile = aws_iam_instance_profile.ssm.name

  # sql_iso_s3_uri         = var.sql_iso_s3_uri
  # sa_password_secret_arn = var.sa_password_secret_arn
  instance_type = "t3.micro"
  root_volume_size = 30
  data_volume_size = 20
  log_volume_size = 10
}

module "sql_test" {
  source = "../modules/sql-server"

  env        = var.env
  role       = "test"
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = module.vpc.vpc_cidr
  admin_cidr = var.admin_cidr
  subnet_id  = module.vpc.public_subnet_id

  windows_ami_id = "ami-0d99de470a2818d2b" # Windows Server 2016 Base - to run SQL Server 2012 w/ SP4 Update
  iam_instance_profile = aws_iam_instance_profile.ssm.name

  # sql_iso_s3_uri         = var.sql_iso_s3_uri
  # sa_password_secret_arn = var.sa_password_secret_arn

  instance_type = "t3.micro"
  root_volume_size = 30
  data_volume_size = 20
  log_volume_size = 10
}