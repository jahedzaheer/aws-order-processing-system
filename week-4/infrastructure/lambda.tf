# Package five Python Lambda functions into ZIP files.
data "archive_file" "lambda_zip" {
  for_each = toset(["create_order", "get_order", "update_order", "delete_order", "dispatcher"])
  type     = "zip"

  # Read Python code from the Week 4 lambda folder.
  source_file = "${path.module}/../lambda/${each.key}.py"
  output_path = "${path.module}/${each.key}.zip"
}

# Deploy five Lambda functions.
resource "aws_lambda_function" "orders" {
  for_each      = data.archive_file.lambda_zip
  function_name = "${var.project_name}-${var.environment}-${each.key}"

  # Separate IAM role for each Lambda (Least Privilege).
  role = aws_iam_role.lambda[each.key].arn

  # Python entry point and runtime.
  handler = "${each.key}.lambda_handler"
  runtime = "python3.12"

  # Deploy ZIP and detect code changes.
  filename         = each.value.output_path
  source_code_hash = each.value.output_base64sha256
  timeout          = 5

  # Pass DynamoDB table and Lambda names as environment variables.
  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders.name
      CREATE_LAMBDA     = "${var.project_name}-${var.environment}-create_order"
      UPDATE_LAMBDA     = "${var.project_name}-${var.environment}-update_order"
      DELETE_LAMBDA     = "${var.project_name}-${var.environment}-delete_order"
    }
  }

  # Ensure IAM permissions are created before Lambda deployment.
  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs,
    aws_iam_role_policy.lambda_permissions
  ]
}
