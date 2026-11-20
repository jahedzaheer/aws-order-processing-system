# Create the HTTP API.
resource "aws_apigatewayv2_api" "orders" {
  name          = "${var.project_name}-${var.environment}-api"
  protocol_type = "HTTP"
}

# Allow API Gateway to send messages to SQS.
resource "aws_iam_role" "api_sqs_role" {
  name = "${var.project_name}-${var.environment}-api-sqs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Allow sending messages to our queue.
resource "aws_iam_role_policy" "api_sqs" {
  name = "quickcart-api-send-sqs"
  role = aws_iam_role.api_sqs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.order_queue.arn
    }]
  })
}

# Connect POST, PUT and DELETE directly to SQS.
resource "aws_apigatewayv2_integration" "sqs" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_subtype    = "SQS-SendMessage"
  credentials_arn        = aws_iam_role.api_sqs_role.arn
  payload_format_version = "1.0"

  request_parameters = {
    QueueUrl    = aws_sqs_queue.order_queue.url
    MessageBody = "$request.body"
  }

  depends_on = [aws_iam_role_policy.api_sqs]
}

# Create the three asynchronous routes.
resource "aws_apigatewayv2_route" "write" {
  for_each = toset(["POST", "PUT", "DELETE"])

  api_id    = aws_apigatewayv2_api.orders.id
  route_key = "${each.key} /orders"
  target    = "integrations/${aws_apigatewayv2_integration.sqs.id}"
}

# Connect GET directly to the read Lambda.
resource "aws_apigatewayv2_integration" "get" {
  api_id                 = aws_apigatewayv2_api.orders.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.orders["get_order"].invoke_arn
  payload_format_version = "2.0"
}

# Create the read route.
resource "aws_apigatewayv2_route" "get" {
  api_id    = aws_apigatewayv2_api.orders.id
  route_key = "GET /orders/{order_id}"
  target    = "integrations/${aws_apigatewayv2_integration.get.id}"
}

# Allow API Gateway to invoke the read Lambda.
resource "aws_lambda_permission" "get" {
  statement_id  = "AllowAPIGatewayGet"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orders["get_order"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.orders.execution_arn}/*/GET/orders/*"
}

# Automatically deploy API changes.
resource "aws_apigatewayv2_stage" "dev" {
  api_id      = aws_apigatewayv2_api.orders.id
  name        = "$default"
  auto_deploy = true
}
