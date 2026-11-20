# Week 4 — QuickCart AWS Order Request Queue & Processing System

## 1. Project overview

In Week 4, we implemented an AWS-based order processing system using Terraform and Python. The design separates order submission from order processing: API Gateway accepts requests, Amazon SQS buffers write operations, and a dispatcher Lambda invokes the appropriate order-processing Lambda. Amazon DynamoDB stores the orders. CloudWatch provides operational logs and metrics.

The final implementation was deployed and tested in AWS Region **eu-central-1 (Frankfurt)**, then removed with Terraform after the demonstration.

## 2. Architecture

```text
POST /orders ───┐
PUT /orders ────┼──> API Gateway HTTP API ──> SQS main queue
DELETE /orders ─┘                                  │
                                                   ▼
                                          Dispatcher Lambda
                                                   │
                                   ┌───────────────┼───────────────┐
                                   ▼               ▼               ▼
                              Create Lambda   Update Lambda   Delete Lambda
                                   └───────────────┼───────────────┘
                                                   ▼
                                               DynamoDB

GET /orders/{order_id} ──> API Gateway ──> Get Lambda ──> DynamoDB

SQS main queue ──(after repeated processing failures)──> Dead-letter queue
CloudWatch Logs and Metrics monitor Lambda execution and queue activity.
```

**Important:** A successful response to a write request from the API does not by itself prove that the order has already been saved. Write processing happens asynchronously; the result can be checked later in DynamoDB or via the GET endpoint.

## 3. Repository structure

```text
week-4/
├── infrastructure/
│   ├── api_gateway.tf
│   ├── dynamodb.tf
│   ├── iam.tf
│   ├── lambda.tf
│   ├── main.tf
│   ├── sqs.tf
│   ├── sqs_trigger.tf
│   ├── variables.tf
│   ├── outputs.tf.disabled
│   └── cloudwatch-dispatcher-evidence.txt
└── lambda/
    ├── create_order.py
    ├── get_order.py
    ├── update_order.py
    ├── delete_order.py
    └── dispatcher.py
```

The `outputs.tf.disabled` file is not loaded by Terraform. Generated deployment ZIPs, `.terraform/`, Terraform state, and secrets should not be committed.

## 4. Terraform infrastructure

### AWS provider and variables (`main.tf`, `variables.tf`)

- Uses the HashiCorp AWS provider with version constraint `~> 6.0`.
- Configures the AWS CLI profile `quickcart-personal` and region `eu-central-1`.
- Defines `project_name` (default `quickcart-order-processing`) and `environment` (default `dev`) for consistent resource names.

### API Gateway (`api_gateway.tf`)

- Creates an HTTP API with an automatically deployed `$default` stage.
- Configures an AWS service integration (`SQS-SendMessage`) that sends the incoming HTTP request body to the main SQS queue.
- Routes `POST /orders`, `PUT /orders`, and `DELETE /orders` to that SQS integration.
- Routes `GET /orders/{order_id}` to the Get Order Lambda using a Lambda proxy integration.
- Grants API Gateway permission to invoke the Get Order Lambda and an IAM role permission to send messages to the main queue.

### SQS queues (`sqs.tf`)

- Creates the main Standard queue, `quickcart-order-processing-dev-orders`.
- Sets main-queue message retention to **4 days** (`345600` seconds) and visibility timeout to **30 seconds**.
- Creates a dead-letter queue, `quickcart-order-processing-dev-dlq`, with **14-day** retention (`1209600` seconds).
- Sets a redrive policy with `maxReceiveCount = 3`, allowing repeatedly failing messages to move to the DLQ.

### DynamoDB (`dynamodb.tf`)

- Creates `quickcart-order-processing-dev-orders`.
- Uses the string `order_id` as the partition key.
- Uses `PAY_PER_REQUEST` billing mode and resource tags for project and environment identification.

### Lambda deployment (`lambda.tf`)

- Packages each of five Python files using Terraform's `archive_file` data source.
- Deploys five AWS Lambda functions on **Python 3.12** with a **5-second timeout**.
- Uses `source_code_hash` to detect package changes.
- Supplies the DynamoDB table name and write-Lambda names through environment variables.

### IAM permissions (`iam.tf`)

- Gives each Lambda a separate execution role.
- Attaches the AWS-managed `AWSLambdaBasicExecutionRole` for CloudWatch logging.
- Restricts each order Lambda to its relevant DynamoDB action: `PutItem`, `GetItem`, `UpdateItem`, or `DeleteItem`.
- Grants the dispatcher SQS receive/delete/queue-attribute permissions and permission to invoke only the create, update, and delete Lambdas.
- Grants API Gateway only `sqs:SendMessage` on the main queue.

### SQS trigger (`sqs_trigger.tf`)

- Connects the main queue to the Dispatcher Lambda through an event source mapping.
- Enables the trigger and sets `batch_size = 1`, so each invocation handles one SQS message at a time.

## 5. Python Lambda implementation

| File | Responsibility | Behavior |
|---|---|---|
| `dispatcher.py` | Dispatch SQS messages | Parses JSON, validates `operation` and `body`, synchronously invokes the matching write Lambda, and raises an error when processing fails. |
| `create_order.py` | Create an order | Writes `order_id`, `customer_id`, `items`, and `status = PENDING` to DynamoDB; conditional write prevents overwriting an existing order. |
| `get_order.py` | Read an order | Reads `order_id` from API Gateway path parameters, fetches the DynamoDB item, returns 200 if found or 404 if missing. |
| `update_order.py` | Update order status | Updates the `status` field only when the order already exists; returns 404 otherwise. |
| `delete_order.py` | Delete an order | Deletes the order only when it exists; returns 404 if it is missing. |

### Dispatcher message format

Write requests must contain an `operation` and an object-valued `body`. For example:

```json
{
  "operation": "POST",
  "body": {
    "order_id": "30",
    "customer_id": "101",
    "items": ["Laptop"]
  }
}
```

Supported operations are `POST`, `PUT`, and `DELETE`. For `PUT`, the body needs `order_id` and `status`; for `DELETE`, the body needs `order_id`.

The dispatcher invokes the destination Lambda with `InvocationType = "RequestResponse"`. It checks the Lambda invocation for `FunctionError` and checks the returned `statusCode`. If the destination reports an error (400 or above), the dispatcher raises an exception rather than silently treating the message as processed.

### Error handling and retry behavior

The dispatcher raises `ValueError` for malformed JSON, non-object messages, unsupported or missing operations, and invalid request bodies. An invocation failure leaves the SQS message unprocessed; after the visibility timeout, SQS can make it available for another attempt. The configured redrive policy moves repeatedly failing messages to the DLQ after the receive-count threshold is exceeded.

The create, update, and delete functions also handle conditional DynamoDB failures. A duplicate create returns an informational response rather than overwriting an existing order; updates and deletes of nonexistent orders return 404. The dispatcher treats a returned 404 as processing failure, which means such a message can be retried and eventually sent to the DLQ unless the application changes this policy.

## 6. Testing and evidence

The deployed system was demonstrated using AWS CloudShell and the AWS Console:

1. **API request:** The previously used POST request for order `30` was shown in CloudShell during the recording; it was displayed without executing a new order submission.
2. **DynamoDB verification:** Order `30`, customer `101`, item `Laptop`, and status `PENDING` were visible in the orders table.
3. **Main SQS queue:** The queue settings, 30-second visibility timeout, and configured DLQ were inspected. The main queue showed zero available messages after processing.
4. **Dispatcher trigger:** The Lambda console showed the SQS trigger connected to the dispatcher.
5. **DLQ evidence:** The DLQ showed **six available messages** during the inspection.
6. **CloudWatch logs:** Three `ValueError: Invalid JSON message` errors appeared for the dispatcher at approximately **13:18:20**, **13:18:49**, and **13:19:19 UTC** on 17 November 2026. These logs show repeated attempts to process invalid JSON.
7. **Lambda metrics:** CloudWatch `Invocations` and `Errors` were selected for the dispatcher.
8. **SQS metrics:** `ApproximateNumberOfMessagesVisible` was selected for the main queue and the DLQ.

The CloudWatch log timestamps support the retry observation. The DLQ configuration and the visible failed messages support the dead-letter handling demonstration. The available evidence does not uniquely correlate each logged retry with an individual DLQ message ID.

### Functional testing of all order operations

During Week 4 development, the project owner reports that **all updated code was executed and the main order operations worked successfully**, including:

| Operation | Endpoint | Reported result |
|---|---|---|
| POST | `POST /orders` | Order creation tested successfully through the asynchronous processing flow. |
| GET | `GET /orders/{order_id}` | Reading an order from DynamoDB tested successfully. |
| PUT | `PUT /orders` | Updating an existing order tested successfully through the asynchronous processing flow. |
| DELETE | `DELETE /orders` | Deleting an existing order tested successfully through the asynchronous processing flow. |

The project owner also reports that the updated Terraform and Python code ran successfully. The recording and console evidence described above provide **selected examples** of the implementation, rather than a complete recording of every operation. In particular, the recorded demonstration confirms the presence of order `30` and the configured AWS components; it should not be presented as independent video proof of each GET, PUT, or DELETE test. Individual command outputs for all four operations were not supplied with this document.

### Why the demonstration video is short

A **short demonstration video** was intentionally prepared to keep the submission concise. It shows only selected important parts of the system, such as an API request example, the DynamoDB order record, SQS and the dead-letter queue, the Lambda dispatcher trigger, and CloudWatch logs and metrics. **Not every successful test or every code change appears in the video.** The source files and this documentation provide the fuller explanation of the work completed in Week 4.

## 7. Implementation decisions and lessons learned

- **Asynchronous processing:** SQS decouples the HTTP API from order writes, allowing the API to accept a request before downstream processing finishes.
- **Separation of responsibilities:** A dedicated dispatcher routes write operations, while individual Lambdas implement create, read, update, and delete actions.
- **Least-privilege access:** Separate IAM roles and resource-scoped permissions reduce unnecessary access.
- **Safer database changes:** DynamoDB condition expressions prevent accidental overwrite and prevent updating/deleting nonexistent orders.
- **Failure visibility:** CloudWatch logs, queue metrics, retry behavior, and the DLQ make processing failures easier to investigate.
- **Infrastructure as Code:** Terraform provides a reproducible description of the architecture and a way to remove the deployed resources when the exercise is complete.

## 8. Cleanup and cost awareness

After completing the practical demonstration, `terraform destroy` was executed from the local `week-4/infrastructure` directory. Terraform reported:

```text
Destroy complete! Resources: 36 destroyed.
```

A subsequent `terraform state list` produced no entries. This confirms that no resources remained tracked in that Terraform state. It does not by itself prove that every AWS resource outside Terraform was removed.

The AWS account displayed a **Free Plan** with **$160 in remaining credits** at the time of inspection. The Free Tier dashboard showed no listed service offerings at or above their usage limits. Billing detail access was restricted, so an exact total bill was not independently verified.

## 9. How to deploy again (only if needed)

> **Warning:** These commands create real AWS resources and may consume AWS Free Plan credits or incur charges under other account plans. The project was deliberately destroyed after the demonstration; do not redeploy solely for documentation.

Prerequisites: Terraform, AWS credentials configured under the profile `quickcart-personal`, and permissions to create the specified services.

From `week-4/infrastructure`:

```powershell
terraform init
terraform plan
terraform apply
```

To remove the Terraform-managed resources again:

```powershell
terraform destroy
```

Do not commit Terraform state, local credentials, `.tfvars` containing secrets, or generated Lambda ZIP packages.

## 10. Suggested `.gitignore`

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
crash.log
crash.*.log
*.zip
.env
.env.*
__pycache__/
*.pyc
```

Keep the Terraform dependency lock file (`.terraform.lock.hcl`) under version control. Before publishing the repository, review all files for credentials, tokens, account identifiers, and other sensitive information.

## 11. Scope and documentation accuracy

This document describes the **final Week 4 implementation** based on the Terraform and Python source supplied for review and the observed deployment/test results. Earlier source revisions were not provided, so it does **not** claim line-by-line differences from a previous version. The project has been destroyed; the architecture and evidence describe the previously deployed system, not currently running AWS resources.



---

## Appendix A — Complete final Week 4 source code

The following listings reproduce the final Terraform and Python source code supplied for this documentation. The listings are grouped by their original filenames. They document the final implementation; a line-by-line change history cannot be established without earlier revisions. The code is included for review, but the real `.tf` and `.py` files should also be committed separately to GitHub.

**Important implementation note:** The API Gateway SQS integration sends the raw request body to SQS. The dispatcher expects a JSON envelope with `operation` (`POST`, `PUT`, or `DELETE`) and an object-valued `body`. Clients must send that envelope for asynchronous processing to succeed.


### `infrastructure/api_gateway.tf`

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


### `infrastructure/dynamodb.tf`

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


### `infrastructure/iam.tf`

```hcl
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
```


### `infrastructure/lambda.tf`

```hcl
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
```


### `infrastructure/main.tf`

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


### `infrastructure/sqs_trigger.tf`

```hcl
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
```


### `infrastructure/sqs.tf`

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
```


### `infrastructure/variables.tf`

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


### `lambda/create_order.py`

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


### `lambda/delete_order.py`

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


### `lambda/dispatcher.py`

```python
import json
import os
import boto3

client = boto3.client("lambda")

functions = {
    "POST": os.environ["CREATE_LAMBDA"],
    "PUT": os.environ["UPDATE_LAMBDA"],
    "DELETE": os.environ["DELETE_LAMBDA"]
}


def lambda_handler(event, context):
    for record in event["Records"]:
        try:
            message = json.loads(record["body"])
        except (json.JSONDecodeError, TypeError):
            raise ValueError("Invalid JSON message")

        if not isinstance(message, dict):
            raise ValueError("Message must be a JSON object")

        operation = message.get("operation")
        body = message.get("body")

        if operation not in functions:
            raise ValueError("Missing or unsupported operation")

        if not isinstance(body, dict):
            raise ValueError("Missing or invalid order body")

        response = client.invoke(
            FunctionName=functions[operation],
            InvocationType="RequestResponse",
            Payload=json.dumps(body).encode("utf-8")
        )

        result = json.loads(response["Payload"].read())

        if (response.get("FunctionError")
                or result.get("statusCode", 500) >= 400):
            raise RuntimeError("Order processing failed")

        print("Dispatched successfully:", operation)
```


### `lambda/get_order.py`

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


### `lambda/update_order.py`

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


## Appendix B — Publication safety

Do not commit `terraform.tfstate`, `terraform.tfstate.backup`, `.terraform/`, private credentials, secret-containing `.tfvars`, or generated ZIP archives. The source listings above contain no Terraform state. Review the project directory again before publishing.
