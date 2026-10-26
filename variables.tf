# ---------------------------------------------------------------------------
# Naming and tagging
# ---------------------------------------------------------------------------
variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module."
  type        = string
  default     = "ses-monitoring"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,32}$", var.name_prefix))
    error_message = "name_prefix must be 1-33 alphanumeric or hyphen characters and start with alphanumeric."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}

variable "configuration_set_name" {
  description = "Name of the SES configuration set. Defaults to `name_prefix`."
  type        = string
  default     = null
}

variable "events_topic_name" {
  description = "Name of the SES events SNS topic. Defaults to \"<name_prefix>-events-<region>\"."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Identities
# ---------------------------------------------------------------------------
variable "identities" {
  description = <<-EOT
    Verified SES identities (domains and/or email addresses) in the primary
    region whose events should be captured. The module attaches its configuration
    set as each identity's *default* configuration set, so existing senders are
    captured without any application change.
  EOT
  type        = list(string)
  default     = []
}

variable "attach_default_configuration_set" {
  description = <<-EOT
    Attach the configuration set as the default configuration set on each entry of
    `identities`. This uses the AWS CLI through a `null_resource`, because the AWS
    provider cannot set a default configuration set on identities it does not
    manage. Requires AWS CLI v2 wherever Terraform runs. Set to false to manage the
    attachment yourself (e.g. via `aws_sesv2_email_identity.configuration_set_name`).
  EOT
  type        = bool
  default     = true
}

variable "attach_role_arn" {
  description = <<-EOT
    IAM role the AWS CLI assumes before attaching the configuration set to
    `identities`. The CLI uses the credentials of the machine running Terraform,
    not the provider's `assume_role`, so set this when the provider targets
    another account (e.g. its OrganizationAccountAccessRole). Null uses the
    ambient credentials.
  EOT
  type        = string
  default     = null
}

variable "additional_configuration_sets" {
  description = <<-EOT
    Existing configuration sets in the primary region that should also feed the
    pipeline. Each gets one extra SNS event destination; its existing
    destinations are untouched. Needed when senders pass their own
    `ConfigurationSetName`, which overrides an identity's default.
  EOT
  type        = list(string)
  default     = []
}

variable "matching_event_types" {
  description = "SES event types delivered to the pipeline."
  type        = list(string)
  default     = ["SEND", "DELIVERY", "BOUNCE", "COMPLAINT", "REJECT", "DELIVERY_DELAY"]
}

# ---------------------------------------------------------------------------
# DynamoDB
# ---------------------------------------------------------------------------
variable "metrics_table_name" {
  description = "Name of the per-identity daily metrics table. Defaults to \"<name_prefix>-event-metrics\"."
  type        = string
  default     = null
}

variable "suppression_table_name" {
  description = "Name of the suppression (block list) table. Defaults to \"<name_prefix>-suppression-list\"."
  type        = string
  default     = null
}

variable "metrics_ttl_days" {
  description = "Days to retain per-identity daily counter rows (DynamoDB TTL)."
  type        = number
  default     = 90

  validation {
    condition     = var.metrics_ttl_days > 0
    error_message = "metrics_ttl_days must be greater than 0."
  }
}

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode for both tables."
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.dynamodb_billing_mode)
    error_message = "dynamodb_billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "dynamodb_point_in_time_recovery" {
  description = "Enable point-in-time recovery on both DynamoDB tables."
  type        = bool
  default     = true
}

variable "dynamodb_deletion_protection" {
  description = "Enable deletion protection on both DynamoDB tables."
  type        = bool
  default     = false
}

variable "dynamodb_kms_key_arn" {
  description = <<-EOT
    Optional customer managed KMS key ARN for DynamoDB encryption at rest. When
    null the tables use the AWS owned key (still encrypted, at no cost).
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Suppression list
# ---------------------------------------------------------------------------
variable "suppression_bounce_subtypes" {
  description = <<-EOT
    Bounce types recorded in the suppression table. Complaints are always
    recorded. Transient bounces are excluded by default because they are usually
    a full mailbox or a temporary server problem, not a bad address.
  EOT
  type        = list(string)
  default     = ["Permanent"]
}

# ---------------------------------------------------------------------------
# Daily report
# ---------------------------------------------------------------------------
variable "enable_daily_report" {
  description = "Create the daily digest Lambda and its EventBridge schedule."
  type        = bool
  default     = true
}

variable "report_from_address" {
  description = <<-EOT
    From address for the daily digest email. Must belong to a verified SES identity
    in the primary region. Required when `enable_daily_report` is true.
  EOT
  type        = string
  default     = null
}

variable "report_to_addresses" {
  description = "Recipients of the daily digest email. Required when `enable_daily_report` is true."
  type        = list(string)
  default     = []
}

variable "report_schedule_expression" {
  description = "EventBridge schedule for the daily digest (UTC)."
  type        = string
  default     = "cron(0 13 ? * * *)"
}

variable "bounce_threshold" {
  description = "Bounce rate (fraction) at or above which an identity is flagged. AWS considers 5% the danger level."
  type        = number
  default     = 0.05

  validation {
    condition     = var.bounce_threshold > 0 && var.bounce_threshold <= 1
    error_message = "bounce_threshold must be a fraction greater than 0 and at most 1."
  }
}

variable "complaint_threshold" {
  description = "Complaint rate (fraction) at or above which an identity is flagged. AWS considers 0.1% the danger level."
  type        = number
  default     = 0.001

  validation {
    condition     = var.complaint_threshold > 0 && var.complaint_threshold <= 1
    error_message = "complaint_threshold must be a fraction greater than 0 and at most 1."
  }
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------
variable "lambda_runtime" {
  description = "Python runtime for both Lambdas."
  type        = string
  default     = "python3.12"
}

variable "processor_timeout" {
  description = "Timeout in seconds for the event processor Lambda."
  type        = number
  default     = 60
}

variable "processor_memory_size" {
  description = "Memory in MB for the event processor Lambda."
  type        = number
  default     = 128
}

variable "report_timeout" {
  description = "Timeout in seconds for the daily report Lambda."
  type        = number
  default     = 120
}

variable "report_memory_size" {
  description = "Memory in MB for the daily report Lambda."
  type        = number
  default     = 256
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention (days) for both Lambdas."
  type        = number
  default     = 30
}

variable "logs_kms_key_arn" {
  description = "Optional KMS key ARN used to encrypt both Lambda log groups."
  type        = string
  default     = null
}

variable "sns_kms_master_key_id" {
  description = <<-EOT
    Optional KMS key id/ARN for server-side encryption of the SES events topic.
    Must be a customer managed key whose policy allows `ses.amazonaws.com` to
    `kms:GenerateDataKey*` and `kms:Decrypt`; the AWS managed `alias/aws/sns` key
    does not permit SES to publish.
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Optional read-only consumer credentials
# ---------------------------------------------------------------------------
variable "create_metrics_reader_user" {
  description = <<-EOT
    Create an IAM user with read-only (Query/GetItem) access to the metrics table,
    plus a long-lived access key, for a dashboard or another AWS account that
    cannot assume a role. Long-lived keys are a security trade-off — prefer
    `create_metrics_reader_role` where the consumer can assume a role.
  EOT
  type        = bool
  default     = false
}

variable "create_metrics_reader_role" {
  description = <<-EOT
    Create an IAM role with read-only (Query/GetItem) access to the metrics table
    that the principals in `metrics_reader_principals` may assume. Preferred over
    `create_metrics_reader_user` — no long-lived credentials.
  EOT
  type        = bool
  default     = false
}

variable "metrics_reader_principals" {
  description = <<-EOT
    IAM principal ARNs allowed to assume the metrics reader role, e.g.
    ["arn:aws:iam::111122223333:role/dashboard"]. Required when
    `create_metrics_reader_role` is true.
  EOT
  type        = list(string)
  default     = []
}

variable "metrics_reader_external_id" {
  description = <<-EOT
    Optional `sts:ExternalId` required when assuming the metrics reader role. It
    is deliberately not marked sensitive: it is an anti-confused-deputy
    identifier rather than a credential, it is readable in the role's trust
    policy anyway, and marking it sensitive makes it unusable in the `for_each`
    that builds the trust policy condition on Terraform < 1.14.
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Optional alert notifier (alerts.tf)
# ---------------------------------------------------------------------------
variable "alert_topic_arn" {
  description = <<-EOT
    SNS topic to publish bounce and complaint alerts to. Null (the default)
    creates no notifier. May be in another account or region; its policy must
    allow this module's `<name_prefix>-alert-notifier-role` to publish.
  EOT
  type        = string
  default     = null
}

variable "alert_message_format" {
  description = <<-EOT
    `amazon_q`: Amazon Q Developer in chat applications (AWS Chatbot) custom
    notification JSON, for a topic it posts to Slack or Teams (it drops plain
    text). `text`: subject + plain-text body, for email and other subscribers.
  EOT
  type        = string
  default     = "amazon_q"

  validation {
    condition     = contains(["amazon_q", "text"], var.alert_message_format)
    error_message = "alert_message_format must be \"amazon_q\" or \"text\"."
  }
}

variable "alert_bounce_types" {
  description = "Bounce types that raise an alert. Complaints always do."
  type        = list(string)
  default     = ["Permanent"]
}

variable "alert_account_label" {
  description = "Label naming this account in each alert (e.g. its alias). Defaults to the account ID."
  type        = string
  default     = null
}

variable "alert_topic_kms_key_arn" {
  description = "KMS key of the alert topic, if it is encrypted with a customer managed key."
  type        = string
  default     = null
}
