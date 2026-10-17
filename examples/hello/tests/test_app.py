import json
from types import SimpleNamespace

import app

CONTEXT = SimpleNamespace(function_version="7")


def body(event):
    return json.loads(app.handler(event, CONTEXT)["body"])


def test_direct_invocation():
    assert body({"name": "AWS"}) == {"message": "Hello, AWS!", "version": "7"}


def test_query_string_behind_alb_or_http_api():
    assert body({"queryStringParameters": {"name": "ALB"}})["message"] == "Hello, ALB!"


def test_defaults_and_greeting_from_the_environment(monkeypatch):
    monkeypatch.setenv("GREETING", "Hola")
    assert body({})["message"] == "Hola, world!"
