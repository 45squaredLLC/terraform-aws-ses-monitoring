# ---------------------------------------------------------------------------
# DynamoDB: per-identity daily counters
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "metrics" {
  name                        = local.metrics_table_name
  billing_mode                = var.dynamodb_billing_mode
  hash_key                    = "identity"
  range_key                   = "date"
  deletion_protection_enabled = var.dynamodb_deletion_protection

  attribute {
    name = "identity"
    type = "S"
  }

  attribute {
    name = "date"
    type = "S"
  }

  # Lets the daily report list every identity for a given day.
  global_secondary_index {
    name            = "date-index"
    hash_key        = "date"
    range_key       = "identity"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.dynamodb_point_in_time_recovery
  }

  server_side_encryption {
    enabled     = var.dynamodb_kms_key_arn != null
    kms_key_arn = var.dynamodb_kms_key_arn
  }

  tags = merge(var.tags, { Name = local.metrics_table_name })
}

# ---------------------------------------------------------------------------
# DynamoDB: suppression list (bounced/complained addresses) — record only
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "suppression" {
  name                        = local.suppression_table_name
  billing_mode                = var.dynamodb_billing_mode
  hash_key                    = "email"
  deletion_protection_enabled = var.dynamodb_deletion_protection

  attribute {
    name = "email"
    type = "S"
  }

  attribute {
    name = "identity"
    type = "S"
  }

  attribute {
    name = "last_seen"
    type = "S"
  }

  global_secondary_index {
    name            = "identity-index"
    hash_key        = "identity"
    range_key       = "last_seen"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.dynamodb_point_in_time_recovery
  }

  server_side_encryption {
    enabled     = var.dynamodb_kms_key_arn != null
    kms_key_arn = var.dynamodb_kms_key_arn
  }

  tags = merge(var.tags, { Name = local.suppression_table_name })
}

# ---------------------------------------------------------------------------
# Optional alert topic
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  count = local.create_alert_topic ? 1 : 0

  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.sns_kms_master_key_id
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# Primary-region capture pipeline
# ---------------------------------------------------------------------------
module "primary_pipeline" {
  source = "./modules/region-pipeline"

  name_prefix                      = var.name_prefix
  identities                       = var.identities
  attach_default_configuration_set = var.attach_default_configuration_set
  matching_event_types             = var.matching_event_types

  metrics_table_name     = aws_dynamodb_table.metrics.name
  metrics_table_arn      = aws_dynamodb_table.metrics.arn
  suppression_table_name = aws_dynamodb_table.suppression.name
  suppression_table_arn  = aws_dynamodb_table.suppression.arn
  tables_region          = local.region

  alert_sns_topic_arn   = local.alert_topic_arn
  alert_bounce_subtypes = var.alert_bounce_subtypes
  metrics_ttl_days      = var.metrics_ttl_days

  lambda_runtime        = var.lambda_runtime
  lambda_timeout        = var.processor_timeout
  lambda_memory_size    = var.processor_memory_size
  log_retention_days    = var.log_retention_days
  kms_key_arn           = var.logs_kms_key_arn
  sns_kms_master_key_id = var.sns_kms_master_key_id

  tags = var.tags
}
