# Minimal single-region deployment: capture SES events for two identities,
# store per-identity counters, and email a daily digest.

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
  region = var.region
}

module "ses_monitoring" {
  source = "../../"

  identities = [
    "example.com",
    "notifications@example.com",
  ]

  report_from_address = "ses-reports@example.com"
  report_to_addresses = ["ops@example.com"]

  tags = {
    Project = "ses-monitoring"
  }
}

# The extension point for your own notifications: subscribe a consumer to this
# topic, optionally with a message-body filter policy for Bounce/Complaint only.
output "events_topic_arn" {
  value = module.ses_monitoring.events_topic_arn
}

output "metrics_table_name" {
  value = module.ses_monitoring.metrics_table_name
}
