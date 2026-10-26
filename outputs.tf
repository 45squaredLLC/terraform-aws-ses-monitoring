output "metrics_table_name" {
  description = "Name of the per-identity daily metrics DynamoDB table."
  value       = aws_dynamodb_table.metrics.name
}

output "metrics_table_arn" {
  description = "ARN of the per-identity daily metrics DynamoDB table."
  value       = aws_dynamodb_table.metrics.arn
}

output "suppression_table_name" {
  description = "Name of the suppression (block list) DynamoDB table."
  value       = aws_dynamodb_table.suppression.name
}

output "suppression_table_arn" {
  description = "ARN of the suppression (block list) DynamoDB table."
  value       = aws_dynamodb_table.suppression.arn
}

output "tables_region" {
  description = "Region the DynamoDB tables live in. Pass to `modules/region-pipeline` for additional regions."
  value       = local.region
}

output "configuration_set_name" {
  description = "Name of the SES configuration set created in the primary region."
  value       = module.primary_pipeline.configuration_set_name
}

output "events_topic_arn" {
  description = <<-EOT
    ARN of the SNS topic receiving raw SES events in the primary region. This is
    the extension point for notifications: subscribe your own consumer here, with
    an SNS message-body filter policy if you only want some event types.
  EOT
  value       = module.primary_pipeline.events_topic_arn
}

output "processor_function_name" {
  description = "Name of the SES event processor Lambda in the primary region."
  value       = module.primary_pipeline.processor_function_name
}

output "processor_function_arn" {
  description = "ARN of the SES event processor Lambda in the primary region."
  value       = module.primary_pipeline.processor_function_arn
}

output "daily_report_function_name" {
  description = "Name of the daily report Lambda, or null when disabled."
  value       = local.report_enabled ? aws_lambda_function.report[0].function_name : null
}

output "daily_report_function_arn" {
  description = "ARN of the daily report Lambda, or null when disabled."
  value       = local.report_enabled ? aws_lambda_function.report[0].arn : null
}

output "metrics_reader_role_arn" {
  description = "ARN of the read-only metrics reader role, or null when not created."
  value       = var.create_metrics_reader_role ? aws_iam_role.metrics_reader[0].arn : null
}

output "metrics_reader_user_name" {
  description = "Name of the read-only metrics reader IAM user, or null when not created."
  value       = var.create_metrics_reader_user ? aws_iam_user.metrics_reader[0].name : null
}

output "metrics_reader_access_key_id" {
  description = "Access key id for the metrics reader IAM user, or null when not created."
  value       = var.create_metrics_reader_user ? aws_iam_access_key.metrics_reader[0].id : null
}

output "metrics_reader_secret_access_key" {
  description = <<-EOT
    Secret access key for the metrics reader IAM user, or null when not created.
    This value is written to Terraform state in plaintext — protect your state
    backend, and prefer `create_metrics_reader_role` where possible.
  EOT
  value       = var.create_metrics_reader_user ? aws_iam_access_key.metrics_reader[0].secret : null
  sensitive   = true
}

output "alert_notifier_function_arn" {
  description = "ARN of the alert notifier Lambda (null unless alert_topic_arn is set). Subscribe it to additional regions' events topics."
  value       = local.alert_enabled ? aws_lambda_function.alert[0].arn : null
}

output "alert_notifier_role_arn" {
  description = "ARN of the alert notifier's role, for the alert topic's policy (null unless alert_topic_arn is set)."
  value       = local.alert_enabled ? aws_iam_role.alert[0].arn : null
}
