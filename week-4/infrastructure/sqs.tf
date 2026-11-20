# Store messages that fail repeatedly.
resource "aws_sqs_queue" "order_dlq" {
  name                      = "${var.project_name}-${var.environment}-dlq"
  message_retention_seconds = 1209600 # Keep failed messages for 14 days.

  tags = {
    Name        = "${var.project_name}-${var.environment}-dlq"
    Environment = var.environment
    Project     = var.project_name
  }
}

# Store incoming order requests.
resource "aws_sqs_queue" "order_queue" {
  name                       = "${var.project_name}-${var.environment}-orders"
  message_retention_seconds  = 345600 # Keep messages for 4 days.
  visibility_timeout_seconds = 30     # Allow more time for processing.

  # Move messages to the DLQ after repeated failures.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-orders"
    Environment = var.environment
    Project     = var.project_name
  }
}
