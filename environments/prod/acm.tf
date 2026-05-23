resource "aws_acm_certificate" "main" {
  domain_name               = "asinbase.com"
  subject_alternative_names = ["*.asinbase.com"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-cert"
  }
}


# safety net for cert validation
resource "aws_acm_certificate_validation" "main" {
  certificate_arn = aws_acm_certificate.main.arn

  timeouts {
    create = "30m"
  }
}