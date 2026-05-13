module "vpc" {
  source              = "../modules/vpc"
  env                 = var.env
  region              = var.region
  cidr                = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.3.0/24"
  private_subnet_cidr = "10.0.1.0/24"
}

locals {
  winrm_bootstrap_script = templatefile("${path.module}/../../scripts/bootstrap/Bootstrap-WinRMHttps.ps1", {
    automation_admin_username_b64 = base64encode(var.automation_admin_username)
    automation_admin_password_b64 = base64encode(var.automation_admin_password)
  })

  winrm_bootstrap_user_data = <<-EOF
  <powershell>
  ${local.winrm_bootstrap_script}
  </powershell>
  EOF
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

  windows_ami_id       = var.live_windows_ami_id
  iam_instance_profile = aws_iam_instance_profile.ssm.name
  user_data            = local.winrm_bootstrap_user_data

  # sql_iso_s3_uri         = var.sql_iso_s3_uri
  # sa_password_secret_arn = var.sa_password_secret_arn
  enable_rdp       = true
  instance_type    = "t3.micro"
  root_volume_size = 30
  data_volume_size = 20
  log_volume_size  = 10

  # Explicit dependency to avoid a race condition where the instance launches before
  # the instance profile is fully created, leaving the SSM agent without a role.
  depends_on = [aws_iam_instance_profile.ssm]
}

module "sql_test" {
  source = "../modules/sql-server"

  env        = var.env
  role       = "test"
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = module.vpc.vpc_cidr
  admin_cidr = var.admin_cidr
  subnet_id  = module.vpc.public_subnet_id

  windows_ami_id       = var.test_windows_ami_id
  iam_instance_profile = aws_iam_instance_profile.ssm.name
  user_data            = local.winrm_bootstrap_user_data

  # sql_iso_s3_uri         = var.sql_iso_s3_uri
  # sa_password_secret_arn = var.sa_password_secret_arn

  enable_rdp       = true
  instance_type    = "t3.micro"
  root_volume_size = 30
  data_volume_size = 20
  log_volume_size  = 10

  # Explicit dependency to avoid a race condition where the instance launches before
  # the instance profile is fully created, leaving the SSM agent without a role.
  depends_on = [aws_iam_instance_profile.ssm]
}
