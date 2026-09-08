data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  metrics_table_name     = coalesce(var.metrics_table_name, "${var.name_prefix}-event-metrics")
  suppression_table_name = coalesce(var.suppression_table_name, "${var.name_prefix}-suppression-list")

  report_function_name = "${var.name_prefix}-daily-report"
  report_log_group     = "/aws/lambda/${local.report_function_name}"

  create_alert_topic = var.alert_sns_topic_arn == null && var.create_alert_topic
  alert_topic_arn = var.alert_sns_topic_arn != null ? var.alert_sns_topic_arn : (
    local.create_alert_topic ? aws_sns_topic.alerts[0].arn : null
  )
  alerts_enabled = local.alert_topic_arn != null

  report_enabled = var.enable_daily_report

  report_source_file = "${path.module}/lambda/ses_daily_report.py"
  report_build_path  = "${path.module}/.build/ses_daily_report.zip"
}
