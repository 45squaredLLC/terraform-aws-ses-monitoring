data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  region                 = data.aws_region.current.name
  configuration_set_name = coalesce(var.configuration_set_name, var.name_prefix)

  processor_function_name = "${var.name_prefix}-event-processor-${local.region}"
  events_topic_name       = coalesce(var.events_topic_name, "${var.name_prefix}-events-${local.region}")

  lambda_source_file = "${path.module}/lambda/ses_event_processor.py"
  lambda_build_path  = "${path.module}/.build/ses_event_processor_${local.region}.zip"

  log_group_name = "/aws/lambda/${local.processor_function_name}"
}
