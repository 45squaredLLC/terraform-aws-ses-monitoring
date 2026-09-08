# Changelog

All notable changes to this module are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-08

Initial public release.

### Added

- Per-region SES v2 configuration set with an SNS event destination and an event
  processor Lambda that writes per-identity daily counters to DynamoDB.
- Suppression (block list) table recording every permanently bounced or
  complained address, with first/last seen timestamps and a hit counter.
- Optional real-time alerts for permanent bounces and complaints, to a topic you
  supply or one the module creates.
- Optional daily HTML digest email with per-identity bounce/complaint rates and
  the last 24 hours of suppression-list additions.
- `modules/region-pipeline` submodule for capturing events in additional regions
  into the same tables.
- Optional read-only consumer access to the metrics table, as an assumable IAM
  role (preferred) or an IAM user with an access key.
