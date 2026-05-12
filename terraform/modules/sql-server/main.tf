resource "aws_security_group" "sql" {
  name   = "${var.env}-${var.role}-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port   = 5986
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "sql_server" {
  ami                    = var.windows_ami_id
  subnet_id              = var.subnet_id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.sql.id]
  iam_instance_profile   = var.iam_instance_profile
  user_data              = var.user_data

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  ebs_block_device {
    device_name = "/dev/sdf"
    volume_size = var.data_volume_size
    volume_type = "gp3"
  }

  ebs_block_device {
    device_name = "/dev/sdg"
    volume_size = var.log_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.env}-${var.role}"
  }
}
