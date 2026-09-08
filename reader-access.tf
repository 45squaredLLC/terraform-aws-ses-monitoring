# ---------------------------------------------------------------------------
# Optional read-only access to the metrics table for an external consumer
# (a dashboard, another account, a BI job).
#
# Prefer the role: it hands out short-lived credentials. The IAM user exists for
# consumers that cannot assume a role; its access key is a long-lived credential
# that you are responsible for rotating.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "metrics_reader" {
  count = var.create_metrics_reader_user || var.create_metrics_reader_role ? 1 : 0

  statement {
    sid    = "ReadMetricsTable"
    effect = "Allow"
    actions = [
      "dynamodb:Query",
      "dynamodb:GetItem",
    ]
    resources = [
      aws_dynamodb_table.metrics.arn,
      "${aws_dynamodb_table.metrics.arn}/index/*",
    ]
  }
}

# --- Role (preferred) -------------------------------------------------------
data "aws_iam_policy_document" "metrics_reader_assume" {
  count = var.create_metrics_reader_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.metrics_reader_principals
    }

    dynamic "condition" {
      for_each = var.metrics_reader_external_id != null ? [var.metrics_reader_external_id] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [condition.value]
      }
    }
  }
}

resource "aws_iam_role" "metrics_reader" {
  count = var.create_metrics_reader_role ? 1 : 0

  name               = "${var.name_prefix}-metrics-reader"
  description        = "Read-only access to the SES metrics table"
  assume_role_policy = data.aws_iam_policy_document.metrics_reader_assume[0].json
  tags               = var.tags

  lifecycle {
    precondition {
      condition     = length(var.metrics_reader_principals) > 0
      error_message = "metrics_reader_principals must not be empty when create_metrics_reader_role is true."
    }
  }
}

resource "aws_iam_role_policy" "metrics_reader" {
  count = var.create_metrics_reader_role ? 1 : 0

  name   = "${var.name_prefix}-metrics-readonly"
  role   = aws_iam_role.metrics_reader[0].id
  policy = data.aws_iam_policy_document.metrics_reader[0].json
}

# --- IAM user with a long-lived access key (opt-in) -------------------------
resource "aws_iam_user" "metrics_reader" {
  count = var.create_metrics_reader_user ? 1 : 0

  name = "${var.name_prefix}-metrics-reader"
  tags = merge(var.tags, { Purpose = "Read-only SES metrics access" })
}

resource "aws_iam_user_policy" "metrics_reader" {
  count = var.create_metrics_reader_user ? 1 : 0

  name   = "${var.name_prefix}-metrics-readonly"
  user   = aws_iam_user.metrics_reader[0].name
  policy = data.aws_iam_policy_document.metrics_reader[0].json
}

resource "aws_iam_access_key" "metrics_reader" {
  count = var.create_metrics_reader_user ? 1 : 0

  user = aws_iam_user.metrics_reader[0].name
}
