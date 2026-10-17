"""Example function: greets the name in the event or in the query string (ALB, HTTP API)."""

import json
import os


def handler(event, context):
    query = event.get("queryStringParameters") or {}
    name = query.get("name") or event.get("name") or "world"
    greeting = os.environ.get("GREETING", "Hello")
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {"message": f"{greeting}, {name}!", "version": context.function_version}
        ),
    }
