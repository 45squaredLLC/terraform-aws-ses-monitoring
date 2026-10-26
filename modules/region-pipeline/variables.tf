variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module."
  type        = string
  default     = "ses-monitoring"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,32}$", var.name_prefix))
    error_message = "name_prefix must be 1-33 alphanumeric or hyphen characters and start with alphanumeric."
  }
}

variable "configuration_set_name" {
  description = "Name of the SES v2 configuration set created in this region. Defaults to `name_prefix`."
  type        = string
  default     = null
}

variable "events_topic_name" {
  description = "Name of the SES events SNS topic. Defaults to \"<name_prefix>-events-<region>\"."
  type        = string
  default     = null
}

variable "identities" {
  description = <<-EOT
    SES identities (verified domains and/or email addresses) in this region whose
    events should be captured. Used only when `attach_default_configuration_set`
    is true, in which case the module sets this configuration set as the identity's
    default so all mail is captured without changing senders.
  EOT
  type        = list(string)
  default     = []
}

variable "attach_default_configuration_set" {
  description = <<-EOT
    Attach the configuration set as the *default* configuration set on each entry
    of `identities` via the AWS CLI (`aws sesv2 put-email-identity-configuration-set-attributes`).
    The AWS provider has no resource for this on identities it does not manage, so a
    `null_resource` + `local-exec` is used. Requires the AWS CLI v2 on the machine
    running Terraform. Set to false if you attach configuration sets yourself.
  EOT
  type        = bool
  default     = true
}

variable "attach_role_arn" {
  description = <<-EOT
    IAM role the AWS CLI assumes before attaching the configuration set. The CLI
    runs with the credentials of the machine running Terraform, not with the
    provider's `assume_role`, so set this when the provider targets another
    account. Null (the default) uses the ambient credentials.
  EOT
  type        = string
  default     = null
}

variable "additional_configuration_sets" {
  description = <<-EOT
    Existing configuration sets (in this region and account) that should also
    feed the pipeline. An extra SNS event destination is added to each; their
    existing destinations are left alone. Use this when senders name their own
    configuration set, which overrides an identity's default.
  EOT
  type        = list(string)
  default     = []
}

variable "matching_event_types" {
  description = "SES event types delivered to the pipeline."
  type        = list(string)
  default     = ["SEND", "DELIVERY", "BOUNCE", "COMPLAINT", "REJECT", "DELIVERY_DELAY"]
}

variable "metrics_table_name" {
  description = "Name of the per-identity daily metrics DynamoDB table."
  type        = string
}

variable "metrics_table_arn" {
  description = "ARN of the per-identity daily metrics DynamoDB table."
  type        = string
}

variable "suppression_table_name" {
  description = "Name of the suppression (block list) DynamoDB table."
  type        = string
}

variable "suppression_table_arn" {
  description = "ARN of the suppression (block list) DynamoDB table."
  type        = string
}

variable "tables_region" {
  description = <<-EOT
    Region the DynamoDB tables live in. When this pipeline runs in a different
    region the processor writes cross-region, so the region is pinned explicitly.
  EOT
  type        = string
}

variable "suppression_bounce_subtypes" {
  description = <<-EOT
    Bounce types recorded in the suppression table. Complaints are always
    recorded. Transient bounces are excluded by default because they are usually
    a full mailbox or a temporary server problem, not a bad address.
  EOT
  type        = list(string)
  default     = ["Permanent"]
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

variable "lambda_runtime" {
  description = "Python runtime for the event processor Lambda."
  type        = string
  default     = "python3.12"
}

variable "lambda_timeout" {
  description = "Timeout in seconds for the event processor Lambda."
  type        = number
  default     = 60
}

variable "lambda_memory_size" {
  description = "Memory in MB for the event processor Lambda."
  type        = number
  default     = 128
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention (days) for the event processor Lambda."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN used to encrypt the Lambda log group. Uses the CloudWatch Logs default key when null."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}

variable "sns_kms_master_key_id" {
  description = <<-EOT
    Optional KMS key id/ARN for server-side encryption of the SES events SNS topic.
    Must be a customer managed key whose policy allows `ses.amazonaws.com` to
    `kms:GenerateDataKey*`/`kms:Decrypt` — the AWS managed `alias/aws/sns` key does
    not permit SES to publish. Leave null for an unencrypted topic.
  EOT
  type        = string
  default     = null
}
