"""SES event processor.

Triggered by an SNS topic subscribed to an SES v2 configuration set event
destination (SEND / DELIVERY / BOUNCE / COMPLAINT / REJECT / DELIVERY_DELAY).

For every event it increments a per-identity, per-day counter in the metrics
DynamoDB table. For the configured bounce subtypes (permanent bounces by
default) and for complaints it also records the offending address in the
suppression table.

Notifications are deliberately not part of this function. Subscribe your own
consumer to the SES events SNS topic instead — SNS message-body filter policies
can narrow the subscription to the event types you care about.

The DynamoDB tables live in a single region; this Lambda may run in another
region and write cross-region, so every client is pinned to an explicit region
via environment variables.
"""

import datetime
import json
import os

import boto3

METRICS_TABLE = os.environ["METRICS_TABLE"]
SUPPRESSION_TABLE = os.environ["SUPPRESSION_TABLE"]
SOURCE_REGION = os.environ.get("AWS_REGION", "")
TABLE_REGION = os.environ.get("TABLE_REGION") or SOURCE_REGION
# Bounce subtypes recorded in the suppression table.
SUPPRESSION_BOUNCE_SUBTYPES = set(
    json.loads(os.environ.get("SUPPRESSION_BOUNCE_SUBTYPES") or '["Permanent"]')
)
# Retain raw daily counters for this many days (DynamoDB TTL).
METRICS_TTL_DAYS = int(os.environ.get("METRICS_TTL_DAYS") or "90")

_dynamodb = boto3.resource("dynamodb", region_name=TABLE_REGION)
_metrics = _dynamodb.Table(METRICS_TABLE)
_suppression = _dynamodb.Table(SUPPRESSION_TABLE)

# Map an SES eventType to the counter attribute it increments.
_EVENT_COUNTER = {
    "Send": "sends",
    "Delivery": "deliveries",
    "Bounce": "bounces",
    "Complaint": "complaints",
    "Reject": "rejects",
    "DeliveryDelay": "delivery_delays",
}


def _identity_of(mail):
    """Best-effort sending identity (a domain) for an SES `mail` object."""
    tags = mail.get("tags") or {}
    from_domain = tags.get("ses:from-domain")
    if from_domain:
        # Tag values arrive as a single-element list in the event stream.
        value = from_domain[0] if isinstance(from_domain, list) else from_domain
        return value.strip().lower()
    source = mail.get("source", "") or ""
    if "@" in source:
        return source.split("@")[-1].strip("> ").lower()
    return source.strip().lower()


def _today():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")


def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _bump_counter(identity, counter):
    """Atomically increment one per-identity, per-day counter."""
    ttl = int(
        (
            datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=METRICS_TTL_DAYS)
        ).timestamp()
    )
    _metrics.update_item(
        Key={"identity": identity, "date": _today()},
        UpdateExpression="ADD #c :one SET expires_at = if_not_exists(expires_at, :ttl)",
        ExpressionAttributeNames={"#c": counter},
        ExpressionAttributeValues={":one": 1, ":ttl": ttl},
    )


def _record_suppression(email, identity, reason, subtype, diagnostic):
    """Upsert a bad address into the suppression table."""
    now = _now_iso()
    _suppression.update_item(
        Key={"email": email.lower()},
        UpdateExpression=(
            "SET #identity = :id, #reason = :r, bounce_subtype = :st, "
            "diagnostic_code = :d, #region = :reg, "
            "first_seen = if_not_exists(first_seen, :now), last_seen = :now "
            "ADD #count :one"
        ),
        # count, region, identity and reason are DynamoDB reserved words.
        ExpressionAttributeNames={
            "#count": "count",
            "#region": "region",
            "#identity": "identity",
            "#reason": "reason",
        },
        ExpressionAttributeValues={
            ":id": identity,
            ":r": reason,
            ":st": subtype or "n/a",
            ":d": (diagnostic or "")[:512],
            ":reg": SOURCE_REGION,
            ":now": now,
            ":one": 1,
        },
    )


def _handle_bounce(identity, bounce):
    subtype = bounce.get("bounceType")  # Permanent / Transient / Undetermined
    if subtype not in SUPPRESSION_BOUNCE_SUBTYPES:
        return
    for recipient in bounce.get("bouncedRecipients", []):
        email = recipient.get("emailAddress")
        if not email:
            continue
        diagnostic = recipient.get("diagnosticCode")
        _record_suppression(email, identity, "Bounce", subtype, diagnostic)


def _handle_complaint(identity, complaint):
    for recipient in complaint.get("complainedRecipients", []):
        email = recipient.get("emailAddress")
        if not email:
            continue
        feedback_type = complaint.get("complaintFeedbackType", "n/a")
        _record_suppression(email, identity, "Complaint", feedback_type, None)


def _process_event(notification):
    event_type = notification.get("eventType") or notification.get("notificationType")
    mail = notification.get("mail", {})
    identity = _identity_of(mail)
    if not identity:
        print(f"Skipping event with no derivable identity: {event_type}")
        return

    counter = _EVENT_COUNTER.get(event_type)
    if counter:
        _bump_counter(identity, counter)

    if event_type == "Bounce":
        _handle_bounce(identity, notification.get("bounce", {}))
    elif event_type == "Complaint":
        _handle_complaint(identity, notification.get("complaint", {}))


def lambda_handler(event, context):
    processed = 0
    failed = 0
    for record in event.get("Records", []):
        raw = (record.get("Sns") or {}).get("Message")
        if not raw:
            continue
        try:
            notification = json.loads(raw)
        except (ValueError, TypeError) as exc:
            failed += 1
            print(f"Unparseable SNS message: {exc}")
            continue
        try:
            _process_event(notification)
            processed += 1
        except Exception as exc:  # noqa: BLE001 - never fail the whole batch
            failed += 1
            print(f"Error processing event: {exc}")
    return {"processed": processed, "failed": failed}
