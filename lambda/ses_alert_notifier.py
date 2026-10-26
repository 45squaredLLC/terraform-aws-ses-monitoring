"""Optional alert notifier for SES bounce and complaint events.

Subscribed to the module's SES events topic with a message-body filter policy
(Bounce / Complaint only). Each permanent bounce (types configurable) and each
complaint is published to ALERT_TOPIC_ARN, which may live in another account or
region. Two message formats:

- ``amazon_q``: Amazon Q Developer in chat applications (formerly AWS Chatbot)
  custom-notification JSON. Chatbot drops plain text, so this is the format for
  a topic it posts to Slack or Teams.
- ``text``: a subject and a plain-text body, for email or any other subscriber.

Transient and undetermined bounces are dropped here rather than in the
subscription filter, because an SNS filter policy cannot express
"Complaint OR (Bounce AND bounceType=Permanent)".
"""

import json
import os

import boto3

ALERT_TOPIC_ARN = os.environ["ALERT_TOPIC_ARN"]
MESSAGE_FORMAT = os.environ.get("MESSAGE_FORMAT", "amazon_q")
ACCOUNT_LABEL = os.environ.get("ACCOUNT_LABEL", "")
SUPPRESSION_TABLE = os.environ.get("SUPPRESSION_TABLE", "")
ALERT_BOUNCE_TYPES = set(json.loads(os.environ.get("ALERT_BOUNCE_TYPES") or '["Permanent"]'))

_sns = boto3.client("sns", region_name=ALERT_TOPIC_ARN.split(":")[3])
_REGION = os.environ.get("AWS_REGION", "")


def _identity_of(mail):
    """Best-effort sending identity (a domain) for an SES `mail` object."""
    tags = mail.get("tags") or {}
    from_domain = tags.get("ses:from-domain")
    if from_domain:
        value = from_domain[0] if isinstance(from_domain, list) else from_domain
        return value.strip().lower()
    source = mail.get("source", "") or ""
    if "@" in source:
        return source.split("@")[-1].strip("> ").lower()
    return source.strip().lower()


def _where():
    parts = [p for p in (ACCOUNT_LABEL, _REGION) if p]
    return " / ".join(parts)


def _publish(title, lines):
    where = _where()
    if where:
        lines = lines + [f"Account: {where}"]
    if SUPPRESSION_TABLE:
        lines = lines + [f"Recorded in {SUPPRESSION_TABLE}."]
    if MESSAGE_FORMAT == "text":
        _sns.publish(TopicArn=ALERT_TOPIC_ARN, Subject=title[:99], Message="\n".join(lines))
        return
    body = json.dumps(
        {
            "version": "1.0",
            "source": "custom",
            "content": {
                "textType": "client-markdown",
                "title": f":rotating_light: {title}"[:250],
                "description": "\n".join(lines)[:8000],
            },
        }
    )
    _sns.publish(TopicArn=ALERT_TOPIC_ARN, Message=body)


def _handle_bounce(identity, bounce):
    bounce_type = bounce.get("bounceType")
    if bounce_type not in ALERT_BOUNCE_TYPES:
        return 0
    sent = 0
    for recipient in bounce.get("bouncedRecipients", []):
        email = recipient.get("emailAddress")
        if not email:
            continue
        _publish(
            f"SES {bounce_type} bounce: {identity}",
            [
                f"*{bounce_type} bounce* on identity *{identity}*",
                f"Address: `{email}`",
                f"Subtype: {bounce.get('bounceSubType', 'n/a')}",
                f"Diagnostic: {recipient.get('diagnosticCode') or 'n/a'}",
            ],
        )
        sent += 1
    return sent


def _handle_complaint(identity, complaint):
    sent = 0
    for recipient in complaint.get("complainedRecipients", []):
        email = recipient.get("emailAddress")
        if not email:
            continue
        _publish(
            f"SES complaint: {identity}",
            [
                f"*Complaint* on identity *{identity}*",
                f"Address: `{email}`",
                f"Feedback type: {complaint.get('complaintFeedbackType', 'n/a')}",
            ],
        )
        sent += 1
    return sent


def lambda_handler(event, context):
    sent = 0
    for record in event.get("Records", []):
        raw = (record.get("Sns") or {}).get("Message")
        if not raw:
            continue
        try:
            notification = json.loads(raw)
        except (ValueError, TypeError) as exc:
            print(f"Unparseable SNS message: {exc}")
            continue
        event_type = notification.get("eventType") or notification.get("notificationType")
        identity = _identity_of(notification.get("mail", {}))
        try:
            if event_type == "Bounce":
                sent += _handle_bounce(identity, notification.get("bounce", {}))
            elif event_type == "Complaint":
                sent += _handle_complaint(identity, notification.get("complaint", {}))
        except Exception as exc:  # noqa: BLE001 - never fail the whole batch
            print(f"Error notifying for {event_type} on {identity}: {exc}")
    return {"notifications_sent": sent}
