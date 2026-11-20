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
