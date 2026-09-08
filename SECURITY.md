# Security policy

## Reporting a vulnerability

Please report security issues privately via GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository, rather than opening a public issue. Expect an initial
response within a week.

## Scope and expectations

This module provisions IAM roles and policies, Lambda functions, DynamoDB tables
and SNS topics in your AWS account. A few things are worth knowing:

- **`create_metrics_reader_user` creates a long-lived IAM access key.** Its
  secret is stored in plaintext in your Terraform state. Prefer
  `create_metrics_reader_role`, and protect your state backend.
- **The suppression table stores recipient email addresses** and bounce
  diagnostic text — personal data under GDPR/CCPA. Encrypt it with
  `dynamodb_kms_key_arn` and apply your own retention policy if required.
- **`attach_default_configuration_set` runs the AWS CLI** through a
  `local-exec` provisioner using whatever credentials Terraform holds. Identity
  names are passed via environment variables rather than interpolated into the
  shell command.
- Lambda log output includes exception messages but not full event payloads.
