resource "aws_security_group" "windows" {
  name        = "csa-windows-sg"
  description = "RDP from admin IP only; managed by Terraform, remediation-eligible"

  ingress {
    description = "RDP from admin IP"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "csa-windows-sg"
    Role = var.project_tag
    OS   = "Windows"
  }
}

resource "aws_security_group" "linux" {
  name        = "csa-linux-sg"
  description = "SSH from admin IP only; managed by Terraform, remediation-eligible"

  ingress {
    description = "SSH from admin IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "csa-linux-sg"
    Role = var.project_tag
    OS   = "Linux"
  }
}
