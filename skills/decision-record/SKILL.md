---
name: decision-record
description: Record an immutable architecture or workflow decision, optionally superseding one.
---

# Decision Record

Use `scripts/record.sh` for this workflow. Read [the contract](references/contract.md) for inputs, output, schema, and advanced options before invoking it.

Write only within the durable-memory eligibility policy. Use the scanned transaction-safe entrypoint; do not edit memory directly. Keep high-confidence secret blocking and the explicit per-command `--allow-redact` override. For decisions use decision-record; for project snapshots use project-update; for reusable procedures use runbook-create.

Requires Python 3.11+ and the repository shared helpers.
