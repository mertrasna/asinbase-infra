# Night-down: stop the dev instance at 00:00 and start it at 12:00 (Europe/Berlin)
# to save compute cost outside working hours. Driven by two EventBridge schedules
# that invoke a small Lambda. See Step 1 handler in lambda/night_down.py.

# --- Package the handler ---------------------------------------------------
# Zips lambda/night_down.py into a deployable artifact. Pure source, no deps,
# so a plain zip of the single file is all Lambda needs.
data "archive_file" "night_down" {
  type        = "zip"
  source_file = "${path.module}/lambda/night_down.py"
  output_path = "${path.module}/lambda/night_down.zip"
}

# --- Execution role --------------------------------------------------------
# The identity the Lambda runs as. boto3 picks up its temporary credentials
# automatically; this role is the function's permission boundary.
resource "aws_iam_role" "night_down_lambda" {
  name = "${local.name_prefix}-night-down-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Allow starting/stopping ONLY the dev instance — nothing else in the account.
resource "aws_iam_role_policy" "night_down_ec2" {
  name = "${local.name_prefix}-night-down-ec2"
  role = aws_iam_role.night_down_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StartInstances", "ec2:StopInstances"]
      Resource = "arn:aws:ec2:*:*:instance/${aws_instance.dev.id}"
    }]
  })
}

# Managed policy that lets the function create its log group/streams and write
# logs to CloudWatch — the standard Lambda logging permission set.
resource "aws_iam_role_policy_attachment" "night_down_logs" {
  role       = aws_iam_role.night_down_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- The function ----------------------------------------------------------
resource "aws_lambda_function" "night_down" {
  function_name = "${local.name_prefix}-night-down"
  role          = aws_iam_role.night_down_lambda.arn

  # The zipped artifact + a hash so Terraform redeploys when the code changes.
  filename         = data.archive_file.night_down.output_path
  source_code_hash = data.archive_file.night_down.output_base64sha256

  handler = "night_down.handler" # <file>.<function> -> entry point AWS calls
  runtime = "python3.12"
  timeout = 30

  # Injected so the handler reads it via os.environ["INSTANCE_ID"].
  environment {
    variables = {
      INSTANCE_ID = aws_instance.dev.id
    }
  }
}

# --- Scheduler invoke role -------------------------------------------------
# EventBridge Scheduler assumes this role when a schedule fires, in order to
# invoke the Lambda. Mirror image of the execution role: this governs WHO may
# call the function, not what the function may do.
resource "aws_iam_role" "night_down_scheduler" {
  name = "${local.name_prefix}-night-down-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Allow the scheduler to invoke ONLY the night-down function.
resource "aws_iam_role_policy" "night_down_scheduler_invoke" {
  name = "${local.name_prefix}-night-down-scheduler-invoke"
  role = aws_iam_role.night_down_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.night_down.arn
    }]
  })
}
