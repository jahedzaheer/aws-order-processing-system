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
