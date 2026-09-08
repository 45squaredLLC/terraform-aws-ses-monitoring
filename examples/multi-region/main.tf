# Multi-region deployment.
#
# The root module owns the DynamoDB tables and the daily report in the primary
# region and builds the primary-region capture pipeline. Every additional region
# gets its own `modules/region-pipeline` instance, wired to the same tables — the
# secondary processors write cross-region.

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "ses_monitoring" {
  source = "../../"

  identities = [
    "example.com",
    "notifications@example.com",
  ]

  report_from_address = "ses-reports@example.com"
  report_to_addresses = ["ops@example.com"]

  # Reuse an existing alerting topic (e.g. one fronted by a Slack forwarder).
  alert_sns_topic_arn = var.alert_sns_topic_arn

  tags = {
    Project = "ses-monitoring"
  }
}

module "ses_monitoring_us_east_1" {
  source = "../../modules/region-pipeline"

  providers = {
    aws = aws.us_east_1
  }

  identities = [
    "east.example.com",
  ]

  metrics_table_name     = module.ses_monitoring.metrics_table_name
  metrics_table_arn      = module.ses_monitoring.metrics_table_arn
  suppression_table_name = module.ses_monitoring.suppression_table_name
  suppression_table_arn  = module.ses_monitoring.suppression_table_arn
  tables_region          = module.ses_monitoring.tables_region

  alert_sns_topic_arn = module.ses_monitoring.alert_topic_arn

  tags = {
    Project = "ses-monitoring"
  }
}
