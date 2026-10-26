# Changelog

All notable changes to this module are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-26

### Added

- `attach_role_arn`: a role the AWS CLI assumes before attaching the
  configuration set to `identities`. The CLI step used the ambient credentials,
  so with a provider that assumes a role into another account the attachment
  went to the wrong account. Null keeps the old behaviour.
- `additional_configuration_sets`: existing configuration sets that should also
  feed the pipeline. Each gets one extra SNS event destination
  (`<configuration_set_name>-sns`); its own destinations are untouched. For
  senders that pass `ConfigurationSetName`, which overrides an identity's
  default.

### Fixed

- The daily report now names the module's configuration set on its send. It
  used to inherit the From identity's default set; when that default was some
  other set, SES refused the send (the policy only covers the module's set).
  Its own sends are now counted by the pipeline too. Upgrading redeploys the
  report Lambda.

The two new inputs default to the previous behaviour.

## [1.0.2] - 2026-09-08

### Fixed

- The daily report's `ses:SendEmail` permission was scoped to identity ARNs only.
  Because the module attaches its configuration set as each identity's *default*,
  SES also authorises the send against the configuration-set resource, so the
  report failed with `AccessDenied on ... configuration-set/<name>`. The policy
  now grants both ARNs, still conditioned on `ses:FromAddress`.

  Anyone running 1.0.0 or 1.0.1 with `enable_daily_report = true` should upgrade:
  the failure is silent until the scheduled run.

## [1.0.1] - 2026-09-08

### Fixed

- `metrics_reader_external_id` is no longer marked sensitive. On Terraform
  before 1.14 a sensitive value cannot be used in `for_each`, so
  `create_metrics_reader_role = true` combined with an external id failed to
  validate. The value is an anti-confused-deputy identifier rather than a
  credential and is readable in the role's trust policy regardless.

### Changed

- CI validates against both the oldest supported Terraform (1.9.8) and latest.

## [1.0.0] - 2026-09-08

Initial public release.

### Added

- Per-region SES v2 configuration set with an SNS event destination and an event
  processor Lambda that writes per-identity daily counters to DynamoDB.
- Suppression (block list) table recording every permanently bounced or
  complained address, with first/last seen timestamps and a hit counter.
- Optional daily HTML digest email with per-identity bounce/complaint rates and
  the last 24 hours of suppression-list additions.
- `modules/region-pipeline` submodule for capturing events in additional regions
  into the same tables.
- Optional read-only consumer access to the metrics table, as an assumable IAM
  role (preferred) or an IAM user with an access key.

### Notes

- Notifications are intentionally out of scope. The module exposes
  `events_topic_arn`; subscribe your own consumer, optionally with an SNS
  message-body filter policy for `Bounce`/`Complaint` only.
