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

output "acm_validation_records" {
  value = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
  description = "CNAME records in Namecheap DNS config"
}

# safety net for cert validation
resource "aws_acm_certificate_validation" "main" {
  certificate_arn = aws_acm_certificate.main.arn

  timeouts {
    create = "30m"
  }
}