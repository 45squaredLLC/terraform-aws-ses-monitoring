# ---------------------------------------------------------------------------
# Optional alert notifier
#
# Off unless `alert_topic_arn` is set. A small Lambda subscribed to the primary
# region's events topic (filter: Bounce / Complaint) publishes each permanent
# bounce and each complaint to that topic, which may be in another account or
# region (its policy must allow this Lambda's role to publish). Use
# `amazon_q` format for a topic that Amazon Q Developer posts to Slack/Teams.
# Additional regions: subscribe `alert_notifier_function_arn` to their topics.
# ---------------------------------------------------------------------------
locals {
  alert_enabled       = var.alert_topic_arn != null
  alert_function_name = "${var.name_prefix}-alert-notifier"
  alert_source_file   = "${path.module}/lambda/ses_alert_notifier.py"
  alert_build_path    = "${path.module}/.build/ses_alert_notifier.zip"
}

data "archive_file" "alert" {
  count = local.alert_enabled ? 1 : 0

  type        = "zip"
  source_file = local.alert_source_file
  output_path = local.alert_build_path
}

resource "aws_cloudwatch_log_group" "alert" {
  count = local.alert_enabled ? 1 : 0

  name              = "/aws/lambda/${local.alert_function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = var.tags
}

resource "aws_iam_role" "alert" {
  count = local.alert_enabled ? 1 : 0

  name = "${local.alert_function_name}-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "lambda.amazonaws.com" }
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "alert" {
  count = local.alert_enabled ? 1 : 0

  name = "${local.alert_function_name}-policy"
  role = aws_iam_role.alert[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "PublishAlerts"
          Effect   = "Allow"
          Action   = "sns:Publish"
          Resource = var.alert_topic_arn
        },
        {
          Sid      = "Logs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.alert[0].arn}:*"
        }
      ],
      var.alert_topic_kms_key_arn == null ? [] : [
        {
          Sid      = "EncryptForAlertTopic"
          Effect   = "Allow"
          Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
          Resource = var.alert_topic_kms_key_arn
        }
      ]
    )
  })
}

resource "aws_lambda_function" "alert" {
  count = local.alert_enabled ? 1 : 0

  function_name    = local.alert_function_name
  description      = "Publishes SES bounce and complaint alerts"
  filename         = data.archive_file.alert[0].output_path
  source_code_hash = data.archive_file.alert[0].output_base64sha256
  role             = aws_iam_role.alert[0].arn
  handler          = "ses_alert_notifier.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = 30
  memory_size      = 128
  tags             = var.tags

  environment {
    variables = {
      ALERT_TOPIC_ARN    = var.alert_topic_arn
      MESSAGE_FORMAT     = var.alert_message_format
      ACCOUNT_LABEL      = coalesce(var.alert_account_label, local.account_id)
      ALERT_BOUNCE_TYPES = jsonencode(var.alert_bounce_types)
      SUPPRESSION_TABLE  = aws_dynamodb_table.suppression.name
    }
  }

  depends_on = [aws_iam_role_policy.alert, aws_cloudwatch_log_group.alert]
}

resource "aws_lambda_permission" "alert" {
  count = local.alert_enabled ? 1 : 0

  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alert[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = module.primary_pipeline.events_topic_arn
}

resource "aws_sns_topic_subscription" "alert" {
  count = local.alert_enabled ? 1 : 0

  topic_arn = module.primary_pipeline.events_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alert[0].arn

  filter_policy_scope = "MessageBody"
  filter_policy       = jsonencode({ eventType = ["Bounce", "Complaint"] })

  depends_on = [aws_lambda_permission.alert]
}
