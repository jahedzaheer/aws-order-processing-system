# Define the five Lambda functions.
locals {
  lambda_names = toset(["create_order", "get_order", "update_order", "delete_order", "dispatcher"])
}

# Give each Lambda its own IAM role (Least Privilege).
resource "aws_iam_role" "lambda" {
  for_each = local.lambda_names
  name     = "${var.project_name}-${var.environment}-${each.key}-role"

  # Allow AWS Lambda to assume this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Allow every Lambda to write CloudWatch logs.
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  for_each   = local.lambda_names
  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Grant only the DynamoDB action needed by each order Lambda.
resource "aws_iam_role_policy" "lambda_permissions" {
  for_each = {
    create_order = "dynamodb:PutItem"
    get_order    = "dynamodb:GetItem"
    update_order = "dynamodb:UpdateItem"
    delete_order = "dynamodb:DeleteItem"
  }

  role = aws_iam_role.lambda[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = [each.value]
      Resource = aws_dynamodb_table.orders.arn
    }]
  })
}

# Allow Dispatcher to read and delete SQS messages.
resource "aws_iam_role_policy" "dispatcher_sqs" {
  role = aws_iam_role.lambda["dispatcher"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ]
      Resource = aws_sqs_queue.order_queue.arn
    }]
  })
}

# Allow Dispatcher to invoke only the three write Lambdas.
resource "aws_iam_role_policy" "dispatcher_invoke" {
  role = aws_iam_role.lambda["dispatcher"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [
        "${aws_lambda_function.orders["create_order"].arn}",
        "${aws_lambda_function.orders["update_order"].arn}",
        "${aws_lambda_function.orders["delete_order"].arn}"
      ]
    }]
  })
}
