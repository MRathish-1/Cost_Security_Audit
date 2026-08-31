output "s3_bucket_name" {
  value = aws_s3_bucket.reports.id
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "lambda_function_name" {
  value = aws_lambda_function.report_generator.function_name
}

output "windows_instance_id" {
  value = aws_instance.windows.id
}

output "linux_instance_id" {
  value = aws_instance.linux.id
}

output "confirm_sns_reminder" {
  value = "Check ${var.alert_email} and confirm the SNS subscription before running an audit."
}
