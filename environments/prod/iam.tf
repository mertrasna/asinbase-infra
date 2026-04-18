# The IAM role - an identity that AWS services can "assume". 
resource "aws_iam_role" "ec2_prod" {
  name = "prod-ec2-role"

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
  role       = aws_iam_role.ec2_prod.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Custom policy to read your SSM parameters
resource "aws_iam_role_policy" "read_ssm_params" {
  name = "prod-read-ssm-params"
  role = aws_iam_role.ec2_prod.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      # Scope this to just your prod parameters — don't give access to all SSM params
      Resource = "arn:aws:ssm:*:*:parameter/prod/*"
    }]
  })
}

# The instance profile - a wrapper around the role. EC2 can't attach a role directly. It attaches and instance profile
resource "aws_iam_instance_profile" "ec2_prod" {
  name = "prod-ec2-instance-profile"
  role = aws_iam_role.ec2_prod.name
}