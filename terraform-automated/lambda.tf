data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/csa_report_gen.py"
  output_path = "${path.module}/lambda/function.zip"
}

resource "aws_lambda_function" "report_generator" {
  function_name    = "CSAReportGenerator"
  runtime          = "python3.12"
  handler          = "csa_report_gen.lambda_handler"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }
}
