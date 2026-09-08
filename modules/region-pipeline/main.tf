# ---------------------------------------------------------------------------
# Configuration set -> SNS event destination
# ---------------------------------------------------------------------------
resource "aws_sesv2_configuration_set" "this" {
  configuration_set_name = local.configuration_set_name
  tags                   = var.tags
}

resource "aws_sns_topic" "events" {
  name              = local.events_topic_name
  kms_master_key_id = var.sns_kms_master_key_id
  tags              = var.tags
}

# Only SES, and only from this account, may publish into the topic.
resource "aws_sns_topic_policy" "events" {
  arn = aws_sns_topic.events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSESPublish"
        Effect    = "Allow"
        Principal = { Service = "ses.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.events.arn
        Condition = {
          StringEquals = { "AWS:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

resource "aws_sesv2_configuration_set_event_destination" "sns" {
  configuration_set_name = aws_sesv2_configuration_set.this.configuration_set_name
  event_destination_name = "sns-ses-events"

  event_destination {
    enabled              = true
    matching_event_types = var.matching_event_types

    sns_destination {
      topic_arn = aws_sns_topic.events.arn
    }
  }

  depends_on = [aws_sns_topic_policy.events]
}

# ---------------------------------------------------------------------------
# Attach the configuration set as each identity's default
#
# The AWS provider can only set a default configuration set on identities it
# manages (`aws_sesv2_email_identity`). Identities are usually created outside
# this module, so the attachment goes through the AWS CLI.
# ---------------------------------------------------------------------------
resource "null_resource" "attach_configuration_set" {
  for_each = var.attach_default_configuration_set ? toset(var.identities) : toset([])

  triggers = {
    identity   = each.value
    config_set = local.configuration_set_name
    region     = local.region
  }

  # PutEmailIdentityConfigurationSetAttributes throttles hard when Terraform
  # fans these out in parallel; let the CLI back off and retry adaptively.
  provisioner "local-exec" {
    environment = {
      AWS_RETRY_MODE   = "adaptive"
      AWS_MAX_ATTEMPTS = "10"
      SES_IDENTITY     = each.value
      SES_CONFIG_SET   = local.configuration_set_name
      SES_REGION       = local.region
    }
    command = <<-EOT
      aws sesv2 put-email-identity-configuration-set-attributes \
        --email-identity "$SES_IDENTITY" \
        --configuration-set-name "$SES_CONFIG_SET" \
        --region "$SES_REGION"
    EOT
  }

  depends_on = [aws_sesv2_configuration_set_event_destination.sns]
}

# ---------------------------------------------------------------------------
# Event processor Lambda
# ---------------------------------------------------------------------------
data "archive_file" "processor" {
  type        = "zip"
  source_file = local.lambda_source_file
  output_path = local.lambda_build_path
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_iam_role" "processor" {
  name = "${local.processor_function_name}-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "lambda.amazonaws.com" }
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "processor" {
  name = "${local.processor_function_name}-policy"
  role = aws_iam_role.processor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          # Both writes are atomic UpdateItem upserts; nothing reads or replaces
          # an item, so PutItem/GetItem are not granted.
          Sid    = "UpdateMetricsAndSuppressionList"
          Effect = "Allow"
          Action = ["dynamodb:UpdateItem"]
          Resource = [
            var.metrics_table_arn,
            var.suppression_table_arn,
          ]
        },
        {
          Sid    = "Logs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ]
          Resource = "${aws_cloudwatch_log_group.processor.arn}:*"
        },
      ],
      var.kms_key_arn != null ? [
        {
          Sid      = "LogEncryption"
          Effect   = "Allow"
          Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
          Resource = var.kms_key_arn
        },
      ] : [],
    )
  })
}

resource "aws_lambda_function" "processor" {
  function_name    = local.processor_function_name
  description      = "Aggregates SES events into per-identity DynamoDB counters and a suppression list"
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256
  role             = aws_iam_role.processor.arn
  handler          = "ses_event_processor.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  tags             = var.tags

  environment {
    variables = {
      METRICS_TABLE               = var.metrics_table_name
      SUPPRESSION_TABLE           = var.suppression_table_name
      TABLE_REGION                = var.tables_region
      SUPPRESSION_BOUNCE_SUBTYPES = jsonencode(var.suppression_bounce_subtypes)
      METRICS_TTL_DAYS            = tostring(var.metrics_ttl_days)
    }
  }

  depends_on = [
    aws_iam_role_policy.processor,
    aws_cloudwatch_log_group.processor,
  ]
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.events.arn
}

resource "aws_sns_topic_subscription" "processor" {
  topic_arn = aws_sns_topic.events.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.processor.arn

  depends_on = [aws_lambda_permission.allow_sns]
}
