# The IAM role - an identity that AWS services can "assume". 
resource "aws_iam_role" "ec2_dev" {
  name = "dev-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Policy attachment - defines what role is allowed to do
# Attach the AWS-managed SSM policy (enables Session Manager)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_dev.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Custom policy to read your SSM parameters
resource "aws_iam_role_policy" "read_ssm_params" {
  name = "dev-read-ssm-params"
  role = aws_iam_role.ec2_dev.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      # Scope this to just your dev parameters — don't give access to all SSM params
      Resource = "arn:aws:ssm:*:*:parameter/dev/*"
    }]
  })
}

# Cloutwatch group - just a container for log streams
resource "aws_cloudwatch_log_group" "dev" {
  name              = "/asinbase-backend/dev"
  retention_in_days = 7
}

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "dev-cloudwatch-logs"
  role = aws_iam_role.ec2_dev.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ]
      Resource = "arn:aws:logs:*:*:log-group:/asinbase-backend/dev:*"
    }]
  })
}

# The instance profile - a wrapper around the role. EC2 can't attach a role directly. It attaches and instance profile
resource "aws_iam_instance_profile" "ec2_dev" {
  name = "dev-ec2-instance-profile"
  role = aws_iam_role.ec2_dev.name
}