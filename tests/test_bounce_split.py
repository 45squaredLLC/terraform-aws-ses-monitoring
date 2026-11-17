import json
from decimal import Decimal


def _bounce_event(bounce_type, sub_type, email="records@example.com", diagnostic="smtp; 250 ok"):
    return {
        "Records": [
            {
                "Sns": {
                    "Message": json.dumps(
                        {
                            "eventType": "Bounce",
                            "mail": {
                                "messageId": "msg-1",
                                "source": "forms@example.com",
                                "tags": {"ses:from-domain": ["example.com"]},
                                "commonHeaders": {"subject": "Uploaded Records " + "x" * 500},
                            },
                            "bounce": {
                                "bounceType": bounce_type,
                                "bounceSubType": sub_type,
                                "timestamp": "2026-11-16T15:00:00.000Z",
                                "reportingMTA": "dns; a1-2.smtp-out.amazonses.com",
                                "remoteMtaIp": "192.0.2.10",
                                "bouncedRecipients": [
                                    {"emailAddress": email, "diagnosticCode": diagnostic}
                                ],
                            },
                        }
                    )
                }
            }
        ]
    }


def _counters(processor):
    table = processor._metrics
    return [u["ExpressionAttributeNames"]["#c"] for u in table.updates]


def _soft_lines(out):
    lines = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    return [entry for entry in lines if entry.get("log") == "ses_soft_bounce"]


def test_transient_bounce_counts_and_logs(processor, capsys):
    result = processor.lambda_handler(
        _bounce_event("Transient", "General", diagnostic="d" * 1500), None
    )
    assert result == {"processed": 1, "failed": 0}
    assert _counters(processor) == ["bounces", "bounces_transient"]
    assert processor._suppression.updates == []

    (entry,) = _soft_lines(capsys.readouterr().out)
    assert entry["identity"] == "example.com"
    assert entry["sourceRegion"] == "us-west-2"
    assert entry["recipient"] == "records@example.com"
    assert entry["bounceType"] == "Transient"
    assert entry["bounceSubType"] == "General"
    assert len(entry["diagnosticCode"]) == 1000
    assert entry["reportingMTA"] == "dns; a1-2.smtp-out.amazonses.com"
    assert entry["remoteMtaIp"] == "192.0.2.10"
    assert entry["messageId"] == "msg-1"
    assert entry["source"] == "forms@example.com"
    assert entry["subject"].startswith("Uploaded Records")
    assert len(entry["subject"]) == 200
    assert entry["timestamp"] == "2026-11-16T15:00:00.000Z"


def test_undetermined_bounce_counts_as_transient(processor, capsys):
    processor.lambda_handler(_bounce_event("Undetermined", "Undetermined"), None)
    assert _counters(processor) == ["bounces", "bounces_transient"]
    assert len(_soft_lines(capsys.readouterr().out)) == 1


def test_permanent_bounce_suppresses_without_soft_log(processor, capsys):
    processor.lambda_handler(_bounce_event("Permanent", "General"), None)
    assert _counters(processor) == ["bounces", "bounces_permanent"]
    (update,) = processor._suppression.updates
    assert update["Key"] == {"email": "records@example.com"}
    assert update["ExpressionAttributeValues"][":st"] == "Permanent"
    assert _soft_lines(capsys.readouterr().out) == []


def _row(**counts):
    item = {"identity": "example.com", "date": "2026-11-16"}
    item.update({k: Decimal(v) for k, v in counts.items()})
    return item


def test_rate_uses_permanent_bounces_only(report):
    r = report._summarize(
        _row(sends=29, deliveries=33, bounces=2, bounces_permanent=0, bounces_transient=2)
    )
    assert r["bounce_rate"] == 0.0
    assert r["bounces_permanent"] == 0
    assert r["bounces_transient"] == 2
    assert not r["flagged"]


def test_permanent_rate_flags_at_threshold(report):
    r = report._summarize(
        _row(sends=20, deliveries=19, bounces=3, bounces_permanent=1, bounces_transient=2)
    )
    assert r["bounce_rate"] == 1 / 20
    assert r["flagged"]


def test_old_rows_fall_back_to_all_bounces(report):
    r = report._summarize(_row(sends=29, deliveries=33, bounces=2))
    assert r["bounces_permanent"] == 2
    assert r["bounces_transient"] is None
    assert r["bounce_rate"] == 2 / 35
    assert r["flagged"]


def test_complaint_threshold_unchanged(report):
    r = report._summarize(_row(sends=1000, deliveries=1000, complaints=1))
    assert r["complaint_rate"] == 0.001
    assert r["flagged"]


def test_html_has_split_columns_and_footnote(report):
    rows = [
        report._summarize(
            _row(sends=29, deliveries=33, bounces=2, bounces_permanent=0, bounces_transient=2)
        ),
        report._summarize(_row(sends=5, deliveries=5)),
    ]
    page = report._build_html("2026-11-16", rows, [], [])
    assert "Permanent<br>bounces" in page
    assert "Transient<br>bounces" in page
    assert "n/a" in page  # the old-style row has no transient count
    assert "don't count toward AWS's bounce reputation" in page
