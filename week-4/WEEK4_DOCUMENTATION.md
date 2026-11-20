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

## Appendix — Publication safety

Do not commit `terraform.tfstate`, `terraform.tfstate.backup`, `.terraform/`, private credentials, secret-containing `.tfvars`, or generated ZIP archives. Keep the Terraform and Python source files in the `infrastructure/` and `lambda/` directories.
