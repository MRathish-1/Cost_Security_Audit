data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "windows" {
  ami                  = data.aws_ami.windows.id
  instance_type        = var.instance_type
  vpc_security_group_ids = [aws_security_group.windows.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  user_data            = file("${path.module}/user_data/windows_bootstrap.ps1")

  tags = {
    Name = "csa-windows"
    Role = var.project_tag
    OS   = "Windows"
  }
}

resource "aws_instance" "linux" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type
  vpc_security_group_ids = [aws_security_group.linux.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  user_data            = file("${path.module}/user_data/linux_bootstrap.sh")

  tags = {
    Name = "csa-linux"
    Role = var.project_tag
    OS   = "Linux"
  }
}
