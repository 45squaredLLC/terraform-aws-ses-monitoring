"""SES daily report.

Triggered once a day by EventBridge. Reads the previous UTC day's per-identity
counters from the metrics table (via the `date-index` GSI), computes per-identity
bounce and complaint rates, flags identities over the configured thresholds,
lists addresses added to the suppression list in the last 24 hours, and emails an
HTML digest via SES. When any identity is flagged and an alert topic is
configured, it also publishes a summary to that topic.
"""

import datetime
import html
import os
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Attr, Key

METRICS_TABLE = os.environ["METRICS_TABLE"]
SUPPRESSION_TABLE = os.environ["SUPPRESSION_TABLE"]
ALERT_TOPIC_ARN = os.environ.get("ALERT_TOPIC_ARN", "")
REPORT_FROM = os.environ["REPORT_FROM"]
REPORT_TO = [a.strip() for a in os.environ["REPORT_TO"].split(",") if a.strip()]

# AWS danger thresholds: bounce >= 5%, complaint >= 0.1%.
BOUNCE_THRESHOLD = float(os.environ.get("BOUNCE_THRESHOLD") or "0.05")
COMPLAINT_THRESHOLD = float(os.environ.get("COMPLAINT_THRESHOLD") or "0.001")

_dynamodb = boto3.resource("dynamodb")
_metrics = _dynamodb.Table(METRICS_TABLE)
_suppression = _dynamodb.Table(SUPPRESSION_TABLE)
_ses = boto3.client("ses")
_sns = boto3.client("sns") if ALERT_TOPIC_ARN else None


def _i(value):
    """Coerce a DynamoDB number (Decimal) to int."""
    return int(value) if isinstance(value, (Decimal, int, float)) else 0


def _e(value):
    """Escape a value for interpolation into the HTML report."""
    return html.escape(str(value if value is not None else ""))


def _query_day(date_str):
    items = []
    kwargs = {
        "IndexName": "date-index",
        "KeyConditionExpression": Key("date").eq(date_str),
    }
    while True:
        resp = _metrics.query(**kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            return items
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]


def _new_suppression_entries(since_iso):
    """Scan the suppression table for entries last seen since `since_iso`."""
    items = []
    kwargs = {"FilterExpression": Attr("last_seen").gte(since_iso)}
    while True:
        resp = _suppression.scan(**kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            return items
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]


def _summarize(item):
    sends = _i(item.get("sends"))
    deliveries = _i(item.get("deliveries"))
    bounces = _i(item.get("bounces"))
    complaints = _i(item.get("complaints"))
    rejects = _i(item.get("rejects"))
    # Bounce rate denominator = delivered + bounced (AWS's definition).
    bounce_denom = deliveries + bounces
    bounce_rate = (bounces / bounce_denom) if bounce_denom else 0.0
    complaint_denom = deliveries or sends
    complaint_rate = (complaints / complaint_denom) if complaint_denom else 0.0
    return {
        "identity": item["identity"],
        "sends": sends,
        "deliveries": deliveries,
        "bounces": bounces,
        "complaints": complaints,
        "rejects": rejects,
        "bounce_rate": bounce_rate,
        "complaint_rate": complaint_rate,
        "flagged": bounce_rate >= BOUNCE_THRESHOLD or complaint_rate >= COMPLAINT_THRESHOLD,
    }


def _row(r):
    color = "#ffd6d6" if r["flagged"] else "#ffffff"
    flag = "&#9888;&#65039; " if r["flagged"] else ""
    return (
        f'<tr style="background:{color}">'
        f"<td>{flag}{_e(r['identity'])}</td>"
        f'<td style="text-align:right">{r["sends"]}</td>'
        f'<td style="text-align:right">{r["deliveries"]}</td>'
        f'<td style="text-align:right">{r["bounces"]}</td>'
        f'<td style="text-align:right">{r["bounce_rate"] * 100:.2f}%</td>'
        f'<td style="text-align:right">{r["complaints"]}</td>'
        f'<td style="text-align:right">{r["complaint_rate"] * 100:.3f}%</td>'
        f'<td style="text-align:right">{r["rejects"]}</td>'
        f"</tr>"
    )


def _build_html(date_str, rows, flagged, new_blocks):
    header = (
        "<tr>"
        "<th align='left'>Identity</th><th>Sends</th><th>Delivered</th>"
        "<th>Bounces</th><th>Bounce&nbsp;%</th><th>Complaints</th>"
        "<th>Complaint&nbsp;%</th><th>Rejects</th>"
        "</tr>"
    )
    banner = (
        f'<p style="color:#b00020;font-weight:bold">&#9888;&#65039; {len(flagged)} '
        f"identity(ies) over threshold (bounce &ge; {BOUNCE_THRESHOLD * 100:.2f}%, "
        f"complaint &ge; {COMPLAINT_THRESHOLD * 100:.3f}%)</p>"
        if flagged
        else '<p style="color:#2e7d32">All identities within thresholds.</p>'
    )
    block_section = "<p>No new suppression-list entries in the last 24h.</p>"
    if new_blocks:
        block_rows = "".join(
            f"<tr><td>{_e(b.get('email'))}</td><td>{_e(b.get('identity'))}</td>"
            f"<td>{_e(b.get('reason'))}</td><td>{_e(b.get('bounce_subtype'))}</td></tr>"
            for b in new_blocks
        )
        block_section = (
            f"<h3>New suppression-list entries (24h): {len(new_blocks)}</h3>"
            "<table border='1' cellpadding='6' cellspacing='0' "
            "style='border-collapse:collapse'>"
            "<tr><th align='left'>Address</th><th>Identity</th>"
            "<th>Reason</th><th>Subtype</th></tr>"
            f"{block_rows}</table>"
        )
    return (
        "<html><body style='font-family:Arial,sans-serif'>"
        f"<h2>SES daily report &mdash; {_e(date_str)} (UTC)</h2>"
        f"{banner}"
        "<table border='1' cellpadding='6' cellspacing='0' "
        "style='border-collapse:collapse'>"
        f"{header}{''.join(_row(r) for r in rows)}</table>"
        f"{block_section}"
        "<p style='color:#888;font-size:12px'>Rates use delivered+bounced as the "
        "bounce denominator, matching the AWS definition.</p>"
        "</body></html>"
    )


def lambda_handler(event, context):
    now = datetime.datetime.now(datetime.timezone.utc)
    yesterday = (now - datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    since_iso = (now - datetime.timedelta(hours=24)).isoformat()

    rows = sorted(
        (_summarize(i) for i in _query_day(yesterday)),
        key=lambda r: (not r["flagged"], -r["bounce_rate"], -r["complaint_rate"]),
    )
    flagged = [r for r in rows if r["flagged"]]
    new_blocks = _new_suppression_entries(since_iso)

    subject = (
        f"SES daily report {yesterday} - {len(flagged)} flagged"
        if flagged
        else f"SES daily report {yesterday} - all healthy"
    )

    if rows:
        _ses.send_email(
            Source=REPORT_FROM,
            Destination={"ToAddresses": REPORT_TO},
            Message={
                "Subject": {"Data": subject},
                "Body": {"Html": {"Data": _build_html(yesterday, rows, flagged, new_blocks)}},
            },
        )
    else:
        print(f"No metrics for {yesterday}; skipping email.")

    if flagged and _sns:
        lines = "\n".join(
            f"- {r['identity']}: bounce {r['bounce_rate'] * 100:.2f}% "
            f"({r['bounces']}/{r['deliveries'] + r['bounces']}), "
            f"complaint {r['complaint_rate'] * 100:.3f}% ({r['complaints']})"
            for r in flagged
        )
        _sns.publish(
            TopicArn=ALERT_TOPIC_ARN,
            Subject=f"SES report {yesterday}: {len(flagged)} identity(ies) over threshold"[:100],
            Message=f"*SES daily report {yesterday}* - identities over threshold:\n{lines}",
        )

    return {
        "date": yesterday,
        "identities": len(rows),
        "flagged": len(flagged),
        "new_suppression_entries": len(new_blocks),
    }
