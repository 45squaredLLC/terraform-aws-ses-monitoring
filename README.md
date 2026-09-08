# terraform-aws-ses-monitoring

Per-identity Amazon SES bounce and complaint monitoring — event-driven, with a
daily digest. **No CloudWatch alarms**: the pipeline is SES configuration set →
SNS → Lambda → DynamoDB.

If you send from more than a handful of SES identities, the console gives you one
account-wide reputation number and nothing per identity. A single bad list on one
domain can put the whole account into probation or a sending pause. This module
gives you per-identity daily counters, a record of every address that bounced or
complained, and a daily digest. Notifications are deliberately **not** included:
the module exposes the SES events SNS topic and you bolt your own notifier onto
it — see [Notifications](#notifications).

## What it builds

An editable diagram lives at [`docs/architecture.drawio`](docs/architecture.drawio)
(open at [app.diagrams.net](https://app.diagrams.net)).

```
SES identity (default configuration set = this module's)
   │  SEND / DELIVERY / BOUNCE / COMPLAINT / REJECT / DELIVERY_DELAY
   ▼
SNS <prefix>-events-<region> ──┬▶ Lambda <prefix>-event-processor-<region>
                               │    ├─ ADD counters → DynamoDB <prefix>-event-metrics
                               │    └─ permanent bounce / complaint → DynamoDB <prefix>-suppression-list
                               │
                               └▶ your own notifier (bolt-on, not part of this module)

EventBridge (daily) ───────────▶ Lambda <prefix>-daily-report
                                   ├─ read yesterday's counters via the date-index GSI
                                   ├─ compute per-identity bounce % / complaint %
                                   └─ SES SendEmail HTML digest
```

Attaching the configuration set as each identity's **default** means existing
senders are captured with no application change.

## Usage

```hcl
module "ses_monitoring" {
  source = "github.com/avansledright/terraform-module-ses-monitoring?ref=v1.0.0"

  identities = [
    "example.com",
    "notifications@example.com",
  ]

  report_from_address = "ses-reports@example.com"
  report_to_addresses = ["ops@example.com"]
}
```

Runnable examples: [`examples/single-region`](examples/single-region),
[`examples/multi-region`](examples/multi-region).

### Multiple regions

The root module owns the DynamoDB tables and the daily report. Each additional
region gets a `modules/region-pipeline` instance writing into the same tables:

```hcl
module "ses_monitoring_us_east_1" {
  source = "github.com/avansledright/terraform-module-ses-monitoring//modules/region-pipeline?ref=v1.0.0"

  providers = { aws = aws.us_east_1 }

  identities = ["east.example.com"]

  metrics_table_name     = module.ses_monitoring.metrics_table_name
  metrics_table_arn      = module.ses_monitoring.metrics_table_arn
  suppression_table_name = module.ses_monitoring.suppression_table_name
  suppression_table_arn  = module.ses_monitoring.suppression_table_arn
  tables_region          = module.ses_monitoring.tables_region
}
```

## Notifications

Alerting is out of scope on purpose. Every shop routes alerts differently — Slack,
PagerDuty, Opsgenie, plain email — and baking one in means either a Slack-shaped
module or a pile of options nobody wants. Instead the module hands you
`events_topic_arn`, the SNS topic carrying raw SES events, and you subscribe your
own consumer.

SNS message-body filter policies narrow the subscription without any code:

```hcl
resource "aws_sns_topic_subscription" "bounce_notifier" {
  topic_arn = module.ses_monitoring.events_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.my_notifier.arn

  filter_policy_scope = "MessageBody"
  filter_policy = jsonencode({
    eventType = ["Bounce", "Complaint"]
  })
}
```

Your function then receives only bounce and complaint events, formats them
however you like, and sends them wherever you like. The processor Lambda keeps
recording every event regardless of what you subscribe.

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.3.0 |
| aws | >= 5.0.0, < 7.0.0 |
| archive | >= 2.4.0 |
| null | >= 3.2.0 |

The module supports AWS provider v5 and v6. Under v6 you will see deprecation
warnings for `data.aws_region.name` and `aws_dynamodb_table.hash_key`; their
replacements do not exist in v5, so the module keeps the v5-compatible spelling
until it drops v5 support. The warnings are harmless.

**AWS CLI v2 must be available wherever Terraform runs** when
`attach_default_configuration_set` is true (the default). The AWS provider cannot
set a default configuration set on an identity it does not manage, so the module
calls `aws sesv2 put-email-identity-configuration-set-attributes` through a
`null_resource`. Set the variable to false if you attach configuration sets
yourself — e.g. via `aws_sesv2_email_identity.configuration_set_name` on
identities you do manage in Terraform.

## Data model

**Metrics table** — `identity` (HASH) / `date` `YYYY-MM-DD` (RANGE). Counters
incremented with atomic `ADD`: `sends`, `deliveries`, `bounces`, `complaints`,
`rejects`, `delivery_delays`. GSI `date-index` (`date` HASH / `identity` RANGE)
lets the report list every identity for a day. TTL on `expires_at`
(`metrics_ttl_days`, default 90).

**Suppression table** — a record of bad addresses; it does *not* touch the SES
account-level suppression list. `email` (HASH), attributes `identity`, `reason`,
`bounce_subtype`, `diagnostic_code`, `region`, `first_seen`, `last_seen`,
`count`. GSI `identity-index` (`identity` HASH / `last_seen` RANGE). No TTL.

## Thresholds

The daily report flags an identity at the AWS danger levels:

- **bounce rate ≥ 5%** — `bounces / (deliveries + bounces)`
- **complaint rate ≥ 0.1%** — `complaints / deliveries`

Tune with `bounce_threshold` / `complaint_threshold`. These affect the digest
only — nothing is enforced or blocked on your behalf.

## Inputs

### Identities and events

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `identities` | Verified SES identities in the primary region to capture | `list(string)` | `[]` |
| `suppression_bounce_subtypes` | Bounce types recorded in the suppression table | `list(string)` | `["Permanent"]` |
| `attach_default_configuration_set` | Set the configuration set as each identity's default via the AWS CLI | `bool` | `true` |
| `matching_event_types` | SES event types delivered to the pipeline | `list(string)` | all six |
| `name_prefix` | Prefix for every resource name | `string` | `"ses-monitoring"` |
| `configuration_set_name` | Override the configuration set name | `string` | `name_prefix` |
| `events_topic_name` | Override the events topic name | `string` | `"<name_prefix>-events-<region>"` |
| `tags` | Tags applied to every taggable resource | `map(string)` | `{}` |

### Storage

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `metrics_table_name` | Metrics table name | `string` | `"<name_prefix>-event-metrics"` |
| `suppression_table_name` | Suppression table name | `string` | `"<name_prefix>-suppression-list"` |
| `metrics_ttl_days` | Retention for daily counter rows | `number` | `90` |
| `dynamodb_billing_mode` | `PAY_PER_REQUEST` or `PROVISIONED` | `string` | `"PAY_PER_REQUEST"` |
| `dynamodb_point_in_time_recovery` | Enable PITR on both tables | `bool` | `true` |
| `dynamodb_deletion_protection` | Enable deletion protection | `bool` | `false` |
| `dynamodb_kms_key_arn` | Customer managed key for encryption at rest | `string` | `null` |

### Daily report

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `enable_daily_report` | Create the digest Lambda and its schedule | `bool` | `true` |
| `report_from_address` | From address (must be a verified identity) | `string` | `null` |
| `report_to_addresses` | Digest recipients | `list(string)` | `[]` |
| `report_schedule_expression` | EventBridge schedule, UTC | `string` | `"cron(0 13 ? * * *)"` |
| `bounce_threshold` | Bounce rate that flags an identity | `number` | `0.05` |
| `complaint_threshold` | Complaint rate that flags an identity | `number` | `0.001` |

`report_from_address` and `report_to_addresses` are required when
`enable_daily_report` is true.

### Lambda

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `lambda_runtime` | Python runtime for both functions | `string` | `"python3.12"` |
| `processor_timeout` / `processor_memory_size` | Event processor sizing | `number` | `60` / `128` |
| `report_timeout` / `report_memory_size` | Daily report sizing | `number` | `120` / `256` |
| `log_retention_days` | CloudWatch Logs retention | `number` | `30` |
| `logs_kms_key_arn` | Customer managed key for the log groups | `string` | `null` |
| `sns_kms_master_key_id` | Customer managed key for the events topic | `string` | `null` |

`sns_kms_master_key_id` must be a **customer managed** key whose policy allows
`ses.amazonaws.com` to `kms:GenerateDataKey*` and `kms:Decrypt`. The AWS managed
`alias/aws/sns` key does not permit SES to publish, and SES will silently drop
events if you use it.

### Read-only consumer access

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `create_metrics_reader_role` | Assumable read-only role (preferred) | `bool` | `false` |
| `metrics_reader_principals` | Principals allowed to assume that role | `list(string)` | `[]` |
| `metrics_reader_external_id` | Optional `sts:ExternalId` on the trust policy | `string` | `null` |
| `create_metrics_reader_user` | IAM user + long-lived access key | `bool` | `false` |

## Outputs

| Name | Description |
|------|-------------|
| `metrics_table_name` / `metrics_table_arn` | Metrics table |
| `suppression_table_name` / `suppression_table_arn` | Suppression table |
| `tables_region` | Region the tables live in — pass to `region-pipeline` |
| `configuration_set_name` | Configuration set in the primary region |
| `events_topic_arn` | Raw SES events topic — subscribe your own notifier here |
| `processor_function_name` / `processor_function_arn` | Event processor Lambda |
| `daily_report_function_name` / `daily_report_function_arn` | Digest Lambda, or `null` |
| `metrics_reader_role_arn` | Reader role, or `null` |
| `metrics_reader_user_name` / `metrics_reader_access_key_id` | Reader user, or `null` |
| `metrics_reader_secret_access_key` | Reader secret (sensitive), or `null` |

## Security notes

- IAM is least-privilege throughout. The processor holds exactly
  `dynamodb:UpdateItem` on the two tables — both of its writes are atomic upserts,
  so it needs neither `PutItem` nor `GetItem`. The report holds `dynamodb:Query`
  on the metrics table and its indexes, `dynamodb:Scan` on the suppression table
  only (the metrics table is never scanned), and `ses:SendEmail` restricted to
  identities in your account with a `ses:FromAddress` condition pinning the
  sender. Each function can write only to its own log group.
- The SES events topic accepts publishes only from `ses.amazonaws.com` in your
  own account (`AWS:SourceAccount` condition), and both Lambda trust policies
  carry an `aws:SourceAccount` condition so they cannot be assumed cross-account.
- Neither Lambda is granted `sns:Publish` — they do not send anything outbound
  except the report email.
- `create_metrics_reader_user` produces a long-lived access key whose secret is
  stored **in plaintext in Terraform state**. Use `create_metrics_reader_role`
  unless the consumer genuinely cannot assume a role, and rotate keys you do
  create.
- The suppression table holds recipient email addresses (personal data). Set
  `dynamodb_kms_key_arn` and consider a retention process if that matters to you.
- Bounce diagnostic codes are truncated to 512 characters before storage.

## Verifying a deployment

Use the [SES mailbox simulator](https://docs.aws.amazon.com/ses/latest/dg/send-an-email-from-console.html#send-email-simulator)
— it does not affect your sending reputation, though it *does* write rows into
these tables, so clean up afterwards.

```bash
# Confirm an identity has the configuration set attached
aws sesv2 get-email-identity --email-identity example.com \
  --query ConfigurationSetName

# Send to bounce@simulator.amazonses.com / complaint@simulator.amazonses.com
# from a monitored identity, then:
aws dynamodb get-item --table-name ses-monitoring-suppression-list \
  --key '{"email":{"S":"bounce@simulator.amazonses.com"}}'

# Today's counters
aws dynamodb query --table-name ses-monitoring-event-metrics --index-name date-index \
  --key-condition-expression "#d = :d" \
  --expression-attribute-names '{"#d":"date"}' \
  --expression-attribute-values "{\":d\":{\"S\":\"$(date -u +%F)\"}}"

# Run the digest on demand (it reports the *previous* UTC day)
aws lambda invoke --function-name ses-monitoring-daily-report /tmp/out.json
```

## Cost

Effectively rounding error for typical volumes: DynamoDB on-demand writes (a few
per email), two small Lambdas, SNS deliveries, and CloudWatch Logs. Sending
100k emails a month lands in the low single-digit dollars.

## License

[MIT](LICENSE)
