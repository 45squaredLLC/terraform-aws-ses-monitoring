# Contributing

Thanks for taking the time. Issues and pull requests are welcome.

## Before opening a PR

```bash
terraform fmt -recursive -check
terraform init -backend=false && terraform validate
(cd examples/single-region && terraform init -backend=false && terraform validate)
(cd examples/multi-region  && terraform init -backend=false && terraform validate)
python -m py_compile lambda/ses_daily_report.py modules/region-pipeline/lambda/ses_event_processor.py
```

CI runs the same checks on every push and pull request.

## Guidelines

- Keep the module's defaults safe and least-privilege. New IAM permissions need a
  reason in the PR description.
- Any new input needs a `description`, a sensible default where one exists, and a
  row in the README's input tables.
- Do not commit anything account-specific: no account IDs, ARNs, real domains,
  email addresses, or `.tfvars` files. Examples use `example.com`.
- Lambda code stays dependency-free (standard library plus the `boto3` bundled in
  the Lambda runtime) so no build step is required.
- Changes that alter resource names or remove inputs are breaking — call that out
  so it can go into a major release.

## Testing against a real account

There is no automated acceptance suite. To validate by hand, deploy
`examples/single-region` into a sandbox account with a verified identity and use
the SES mailbox simulator as described in the README. Simulator traffic does not
affect sending reputation but does write rows to the tables — remove them
afterwards.
