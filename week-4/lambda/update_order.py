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
