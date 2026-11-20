# Creates a DynamoDB table to store QuickCart orders
resource "aws_dynamodb_table" "orders" {

  # Table name using the project name and environment
  name = "${var.project_name}-${var.environment}-orders"

  # Charges are based on actual read/write requests
  billing_mode = "PAY_PER_REQUEST"

  # Uses order_id as the primary key
  hash_key = "order_id"

  # Defines order_id as a String (S) attribute
  attribute {
    name = "order_id"
    type = "S"
  }

  # Adds labels to identify the AWS resource
  tags = {
    Name        = "${var.project_name}-${var.environment}-orders"
    Environment = var.environment
    Project     = var.project_name
  }
}
