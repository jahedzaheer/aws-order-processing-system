# Week 2 — QuickCart Asynchronous Order Processing

## Project overview
This project implements asynchronous order processing on AWS using Terraform, API Gateway, Amazon SQS, AWS Lambda, DynamoDB, and CloudWatch.

## Architecture
```text
API Gateway HTTP API
  GET /orders/{order_id} --> get_order Lambda --> DynamoDB
  POST /orders ---------\
  PUT /orders -----------+--> SQS order queue --> dispatcher Lambda
  DELETE /orders -------/                         |
                                                +--> create_order Lambda --> DynamoDB
                                                +--> update_order Lambda --> DynamoDB
                                                +--> delete_order Lambda --> DynamoDB
  Repeatedly failed SQS messages --> Dead Letter Queue (DLQ)
```

## Implementation
- API Gateway routes GET requests directly to the read Lambda and sends POST, PUT, and DELETE requests to SQS.
- SQS buffers incoming write requests until the dispatcher can process them.
- The dispatcher invokes the corresponding create, update, or delete Lambda.
- DynamoDB stores orders by `order_id` using on-demand billing.
- The SQS dead-letter queue is configured with `maxReceiveCount = 3`; DLQ failure handling was configured but not separately demonstrated.
- Terraform manages the AWS infrastructure. The AWS region used for testing was `eu-central-1` (Frankfurt).

## Tests and observed results
| Test | Observed result |
|---|---|
| Create `order-001` | Order stored in DynamoDB with `PENDING` status |
| Read `order-001` | Order retrieved successfully |
| Update `order-001` | Status changed to `SHIPPED` |
| Delete `order-001` | Order removed successfully |
| Read deleted order | `Order not found` returned |
| Pause SQS-to-dispatcher trigger and send five orders | SQS reported `ApproximateNumberOfMessages = 5` |
| Inspect CloudWatch dispatcher logs | `Dispatched successfully: POST`, `PUT`, and `DELETE` |

## Cleanup
After testing, `terraform destroy` reported `Destroy complete! Resources: 25 destroyed.`
Five automatically created Lambda CloudWatch log groups were subsequently deleted separately.
The resources were removed to avoid unnecessary ongoing AWS usage. This document is a record of the implementation and tests, not a claim that the AWS environment remains live.

## Source code
The following are the original uploaded source files, reproduced verbatim.
Terraform files are shown first, followed by Python Lambda functions.

### `main.tf`

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  profile = "quickcart-personal"
  region  = "eu-central-1"
}
```

### `variables.tf`

```hcl

# Define the QuickCart project name.
variable "project_name" {
  description = "Name of the QuickCart project" # Explain the variable.
  type        = string                          # Store the name as text.
  default     = "quickcart-order-processing"    # Set the project name.
}

# Define the deployment environment.
variable "environment" {
  description = "Deployment environment" # Explain the variable.
  type        = string                   # Store the environment as text.
  default     = "dev"                    # Use the development environment.
}
```

### `dynamodb.tf`

```hcl

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
```

### `sqs.tf`

```hcl

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
  visibility_timeout_seconds = 120    # Allow more time for processing.

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
```

### `lambda.tf`

```hcl

# Package the five Lambda functions.
data "archive_file" "lambda_zip" {
  for_each    = toset(["create_order", "get_order", "update_order", "delete_order", "dispatcher"])
  type        = "zip"
  source_file = "${path.module}/../lambda/${each.key}.py"
  output_path = "${path.module}/${each.key}.zip"
}

# Create the Lambda functions.
resource "aws_lambda_function" "orders" {
  for_each         = data.archive_file.lambda_zip
  function_name    = "${var.project_name}-${var.environment}-${each.key}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "${each.key}.lambda_handler"
  runtime          = "python3.12"
  filename         = each.value.output_path
  source_code_hash = each.value.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      ORDERS_TABLE_NAME = aws_dynamodb_table.orders.name
      CREATE_LAMBDA     = "${var.project_name}-${var.environment}-create_order"
      UPDATE_LAMBDA     = "${var.project_name}-${var.environment}-update_order"
      DELETE_LAMBDA     = "${var.project_name}-${var.environment}-delete_order"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_logs,
    aws_iam_role_policy.dynamodb
  ]
}
```

### `iam.tf`

```hcl

# Create the IAM role for Lambda.
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Allow CloudWatch logging.
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allow access to the orders table.
resource "aws_iam_role_policy" "dynamodb" {
  name = "quickcart-dynamodb-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem"
      ]
      Resource = aws_dynamodb_table.orders.arn
    }]
  })
}

# Allow the Dispatcher to read messages from SQS.
resource "aws_iam_role_policy" "sqs" {
  name = "quickcart-sqs-access"
  role = aws_iam_role.lambda_role.id

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

# Allow the Dispatcher to invoke the three write Lambdas.
resource "aws_iam_role_policy" "invoke" {
  name = "quickcart-lambda-invoke"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [
        aws_lambda_function.orders["create_order"].arn,
        aws_lambda_function.orders["update_order"].arn,
        aws_lambda_function.orders["delete_order"].arn
      ]
    }]
  })
}
```

### `sqs_trigger.tf`

```hcl

# Connect the SQS queue to the Dispatcher Lambda.
resource "aws_lambda_event_source_mapping" "dispatcher_sqs" {
  event_source_arn = aws_sqs_queue.order_queue.arn
  function_name    = aws_lambda_function.orders["dispatcher"].arn
  batch_size       = 1 # Process one message at a time.
  enabled          = true

  # Ensure SQS permissions exist before creating the trigger.
  depends_on = [aws_iam_role_policy.sqs]
}
```

### `api_gateway.tf`

```hcl

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
```

### `create_order.py`

```python

import json
import os
import boto3
from botocore.exceptions import ClientError

# Connect to DynamoDB.
table = boto3.resource("dynamodb").Table(os.environ["ORDERS_TABLE_NAME"])


def lambda_handler(event, context):
    # Read the order from the Dispatcher.
    order = {
        "order_id": event["order_id"],
        "customer_id": event["customer_id"],
        "items": event["items"],
        "status": "PENDING"
    }

    try:
        # Create the order only if it does not exist.
        table.put_item(
            Item=order,
            ConditionExpression="attribute_not_exists(order_id)"
        )

    except ClientError as error:
        # Handle an order that already exists.
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return {
                "statusCode": 200,
                "body": json.dumps({"message": "Order already exists"})
            }
        raise

    # Confirm successful creation.
    return {
        "statusCode": 201,
        "body": json.dumps(order)
    }
```

### `get_order.py`

```python

# Official AWS documentation:
# https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/dynamodb/table/get_item.html

import json  # Create JSON responses.
import os  # Read Lambda environment variables.
import boto3  # Connect to AWS DynamoDB.

# Select the orders table.
table = boto3.resource("dynamodb").Table(os.environ["ORDERS_TABLE_NAME"])


def lambda_handler(event, context):  # Handle a GET request from API Gateway.
    # Read the order ID from the URL.
    order_id = event["pathParameters"]["order_id"]

    # Find the order in DynamoDB.
    response = table.get_item(Key={"order_id": order_id})
    order = response.get("Item")  # Extract the order, if it exists.

    if not order:  # Check whether the order was found.
        return {  # Return a not-found response.
            "statusCode": 404,  # Indicate that the order does not exist.
            # Explain the error.
            "body": json.dumps({"error": "Order not found"})
        }

    return {  # Send the order back to API Gateway.
        "statusCode": 200,  # Indicate success.
        "body": json.dumps(order)  # Return the order as JSON.
    }
```

### `update_order.py`

```python

# AWS documentation:
# https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/dynamodb/table/update_item.html

import json
import os
import boto3
from botocore.exceptions import ClientError

# Connect to the orders table.
table = boto3.resource("dynamodb").Table(os.environ["ORDERS_TABLE_NAME"])


def lambda_handler(event, context):
    # Read the order ID and new status from the Dispatcher.
    order_id = event["order_id"]
    status = event["status"]

    try:
        # Update an existing order.
        response = table.update_item(
            Key={"order_id": order_id},
            UpdateExpression="SET #s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": status},
            ConditionExpression="attribute_exists(order_id)",
            ReturnValues="ALL_NEW"
        )

        # Return the updated order.
        return {
            "statusCode": 200,
            "body": json.dumps(response["Attributes"])
        }

    except ClientError as error:
        # Return 404 if the order does not exist.
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return {
                "statusCode": 404,
                "body": json.dumps({"error": "Order not found"})
            }

        # Retry unexpected AWS errors through SQS.
        raise
```

### `delete_order.py`

```python

# AWS documentation:
# https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/dynamodb/table/delete_item.html

import json
import os
import boto3
from botocore.exceptions import ClientError

# Connect to the orders table.
table = boto3.resource("dynamodb").Table(os.environ["ORDERS_TABLE_NAME"])


def lambda_handler(event, context):
    # Read the order ID from the Dispatcher.
    order_id = event["order_id"]

    try:
        # Delete the order if it exists.
        table.delete_item(
            Key={"order_id": order_id},
            ConditionExpression="attribute_exists(order_id)"
        )

    except ClientError as error:
        # Return 404 if the order does not exist.
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return {
                "statusCode": 404,
                "body": json.dumps({"error": "Order not found"})
            }

        # Report unexpected AWS errors.
        raise

    # Confirm successful deletion.
    return {
        "statusCode": 200,
        "body": json.dumps({"message": "Order deleted successfully"})
    }
```

### `dispatcher.py`

```python

import json
import os
import boto3

# Connect to AWS Lambda.
client = boto3.client("lambda")

# Match operations to Lambda functions.
functions = {
    "POST": os.environ["CREATE_LAMBDA"],
    "PUT": os.environ["UPDATE_LAMBDA"],
    "DELETE": os.environ["DELETE_LAMBDA"]
}


def lambda_handler(event, context):
    # Process messages from SQS.
    for record in event["Records"]:
        message = json.loads(record["body"])
        operation = message["operation"]

        # Reject unsupported operations.
        if operation not in functions:
            raise ValueError("Unsupported operation")

        # Read the data for the target Lambda.
        data = message["body"]

        # Invoke the correct Lambda.
        response = client.invoke(
            FunctionName=functions[operation],
            InvocationType="RequestResponse",
            Payload=json.dumps(data).encode("utf-8")
        )

        # Read the Lambda result.
        result = json.loads(response["Payload"].read())

        # Report failures so SQS can retry.
        if response.get("FunctionError") or result.get("statusCode", 500) >= 400:
            raise RuntimeError(f"Order processing failed: {result}")

        print("Dispatched successfully:", operation)
```

