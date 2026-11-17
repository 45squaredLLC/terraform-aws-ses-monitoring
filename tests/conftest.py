"""Load the Lambda sources with boto3 stubbed out, so tests need no AWS access."""

import importlib.util
import os
import sys
import types
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


class FakeTable:
    def __init__(self):
        self.updates = []
        self.items = []

    def update_item(self, **kwargs):
        self.updates.append(kwargs)

    def query(self, **kwargs):
        return {"Items": list(self.items)}

    def scan(self, **kwargs):
        return {"Items": []}


class FakeResource:
    def __init__(self):
        self.tables = {}

    def Table(self, name):  # noqa: N802 - boto3 API name
        return self.tables.setdefault(name, FakeTable())


class FakeSes:
    def __init__(self):
        self.sent = []

    def send_email(self, **kwargs):
        self.sent.append(kwargs)


def _install_fake_boto3():
    boto3 = types.ModuleType("boto3")
    boto3.resource = lambda *a, **k: FakeResource()
    boto3.client = lambda *a, **k: FakeSes()
    dynamodb = types.ModuleType("boto3.dynamodb")
    conditions = types.ModuleType("boto3.dynamodb.conditions")

    class _Cond:
        def __init__(self, *a):
            pass

        def eq(self, *a):
            return self

        def gte(self, *a):
            return self

    conditions.Attr = _Cond
    conditions.Key = _Cond
    sys.modules["boto3"] = boto3
    sys.modules["boto3.dynamodb"] = dynamodb
    sys.modules["boto3.dynamodb.conditions"] = conditions


def _load(name, relpath):
    _install_fake_boto3()
    spec = importlib.util.spec_from_file_location(name, ROOT / relpath)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def processor(monkeypatch):
    monkeypatch.setenv("METRICS_TABLE", "metrics")
    monkeypatch.setenv("SUPPRESSION_TABLE", "suppression")
    monkeypatch.setenv("AWS_REGION", "us-west-2")
    monkeypatch.delenv("SUPPRESSION_BOUNCE_SUBTYPES", raising=False)
    return _load("ses_event_processor", "modules/region-pipeline/lambda/ses_event_processor.py")


@pytest.fixture
def report(monkeypatch):
    monkeypatch.setenv("METRICS_TABLE", "metrics")
    monkeypatch.setenv("SUPPRESSION_TABLE", "suppression")
    monkeypatch.setenv("REPORT_FROM", "reports@example.com")
    monkeypatch.setenv("REPORT_TO", "ops@example.com")
    for var in ("BOUNCE_THRESHOLD", "COMPLAINT_THRESHOLD", "CONFIGURATION_SET"):
        monkeypatch.delenv(var, raising=False)
    os.environ.setdefault("AWS_REGION", "us-west-2")
    return _load("ses_daily_report", "lambda/ses_daily_report.py")
