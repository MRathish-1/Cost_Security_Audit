resource "aws_s3_bucket" "reports" {
  bucket = var.bucket_name

  tags = {
    Role = var.project_tag
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "audit_script" {
  bucket = aws_s3_bucket.reports.id
  key    = "scripts/CSA_audit.ps1"
  source = "${path.module}/lambda/CSA_audit.ps1"
  etag   = filemd5("${path.module}/lambda/CSA_audit.ps1")
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report_generator.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.reports.arn
}

resource "aws_s3_bucket_notification" "trigger_lambda" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.report_generator.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "data/"
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
