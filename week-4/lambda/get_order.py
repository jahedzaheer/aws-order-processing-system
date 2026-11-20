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
