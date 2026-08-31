variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name for audit findings and the audit script."
  type        = string
}

variable "alert_email" {
  description = "Email address to subscribe to the SNS report topic."
  type        = string
}

variable "my_ip_cidr" {
  description = "Your IP in CIDR form (e.g. 111.112.113.114/32), used to restrict RDP/SSH access."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for both fleet members."
  type        = string
  default     = "t3.micro"
}

variable "project_tag" {
  description = "Value used for the Role tag on managed resources - must match the IAM policy's tag condition."
  type        = string
  default     = "CSAManaged"
}
