output "configuration_set_name" {
  description = "Name of the SES configuration set created in this region."
  value       = aws_sesv2_configuration_set.this.configuration_set_name
}

output "events_topic_arn" {
  description = "ARN of the SNS topic receiving SES events in this region."
  value       = aws_sns_topic.events.arn
}

output "processor_function_name" {
  description = "Name of the SES event processor Lambda in this region."
  value       = aws_lambda_function.processor.function_name
}

output "processor_function_arn" {
  description = "ARN of the SES event processor Lambda in this region."
  value       = aws_lambda_function.processor.arn
}

output "processor_role_arn" {
  description = "ARN of the IAM role assumed by the event processor Lambda."
  value       = aws_iam_role.processor.arn
}

output "processor_log_group_name" {
  description = "CloudWatch Logs group for the event processor Lambda."
  value       = aws_cloudwatch_log_group.processor.name
}
