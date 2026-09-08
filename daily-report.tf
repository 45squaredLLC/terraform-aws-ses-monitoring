# ---------------------------------------------------------------------------
# Daily digest Lambda: reads yesterday's counters, emails an HTML report and
# publishes a summary when any identity is over threshold.
# ---------------------------------------------------------------------------
data "archive_file" "report" {
  count = local.report_enabled ? 1 : 0

  type        = "zip"
  source_file = local.report_source_file
  output_path = local.report_build_path
}

resource "aws_cloudwatch_log_group" "report" {
  count = local.report_enabled ? 1 : 0

  name              = local.report_log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = var.tags
}

resource "aws_iam_role" "report" {
  count = local.report_enabled ? 1 : 0

  name = "${local.report_function_name}-role"
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

resource "aws_iam_role_policy" "report" {
  count = local.report_enabled ? 1 : 0

  name = "${local.report_function_name}-policy"
  role = aws_iam_role.report[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          # The report only ever queries the metrics table through date-index.
          Sid    = "QueryMetrics"
          Effect = "Allow"
          Action = ["dynamodb:Query"]
          Resource = [
            aws_dynamodb_table.metrics.arn,
            "${aws_dynamodb_table.metrics.arn}/index/*",
          ]
        },
        {
          # The suppression table is scanned: recent additions are not indexed
          # by time, so there is no key condition to query on.
          Sid      = "ScanSuppressionList"
          Effect   = "Allow"
          Action   = ["dynamodb:Scan"]
          Resource = [aws_dynamodb_table.suppression.arn]
        },
        {
          # Scoped to identities in this account, and to the configured sender.
          Sid      = "SendReportEmail"
          Effect   = "Allow"
          Action   = ["ses:SendEmail", "ses:SendRawEmail"]
          Resource = "arn:${local.partition}:ses:${local.region}:${local.account_id}:identity/*"
          Condition = {
            StringEquals = { "ses:FromAddress" = var.report_from_address }
          }
        },
        {
          Sid      = "Logs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.report[0].arn}:*"
        },
      ],
      var.logs_kms_key_arn != null ? [
        {
          Sid      = "LogEncryption"
          Effect   = "Allow"
          Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
          Resource = var.logs_kms_key_arn
        },
      ] : [],
    )
  })
}

resource "aws_lambda_function" "report" {
  count = local.report_enabled ? 1 : 0

  function_name    = local.report_function_name
  description      = "Emails a daily per-identity SES bounce/complaint digest"
  filename         = data.archive_file.report[0].output_path
  source_code_hash = data.archive_file.report[0].output_base64sha256
  role             = aws_iam_role.report[0].arn
  handler          = "ses_daily_report.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = var.report_timeout
  memory_size      = var.report_memory_size
  tags             = var.tags

  environment {
    variables = {
      METRICS_TABLE       = aws_dynamodb_table.metrics.name
      SUPPRESSION_TABLE   = aws_dynamodb_table.suppression.name
      REPORT_FROM         = var.report_from_address
      REPORT_TO           = join(",", var.report_to_addresses)
      BOUNCE_THRESHOLD    = tostring(var.bounce_threshold)
      COMPLAINT_THRESHOLD = tostring(var.complaint_threshold)
    }
  }

  lifecycle {
    precondition {
      condition     = var.report_from_address != null && var.report_from_address != ""
      error_message = "report_from_address is required when enable_daily_report is true."
    }
    precondition {
      condition     = length(var.report_to_addresses) > 0
      error_message = "report_to_addresses must contain at least one recipient when enable_daily_report is true."
    }
  }

  depends_on = [
    aws_iam_role_policy.report,
    aws_cloudwatch_log_group.report,
  ]
}

resource "aws_cloudwatch_event_rule" "report" {
  count = local.report_enabled ? 1 : 0

  name                = "${local.report_function_name}-trigger"
  description         = "Triggers the SES daily report Lambda"
  schedule_expression = var.report_schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "report" {
  count = local.report_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.report[0].name
  target_id = "SesDailyReportLambda"
  arn       = aws_lambda_function.report[0].arn
}

resource "aws_lambda_permission" "report_events" {
  count = local.report_enabled ? 1 : 0

  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.report[0].arn
}
