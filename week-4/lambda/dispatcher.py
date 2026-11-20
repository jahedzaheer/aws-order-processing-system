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
