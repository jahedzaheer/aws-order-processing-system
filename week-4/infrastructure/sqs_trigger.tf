# Connect the SQS queue to the Dispatcher Lambda.
resource "aws_lambda_event_source_mapping" "dispatcher_sqs" {
  event_source_arn = aws_sqs_queue.order_queue.arn
  function_name    = aws_lambda_function.orders["dispatcher"].arn

  # Process one message at a time.
  batch_size = 1
  enabled    = true

  # Ensure Dispatcher has SQS and Lambda invoke permissions.
  depends_on = [
    aws_iam_role_policy.dispatcher_sqs,
    aws_iam_role_policy.dispatcher_invoke
  ]
}
