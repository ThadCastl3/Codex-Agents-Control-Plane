---
name: decision-check
description: Resolve applicable accepted decisions before architecture or workflow changes.
---

# Decision Check

Use `scripts/check.sh` for this workflow. Read [the contract](references/contract.md) for inputs, output, schema, and advanced options before invoking it.

This is a read-only workflow. Do not expose sensitive values or modify source documents. Decision graph errors return 3; unavailable dependencies or invalid inputs return 2. Use context-bootstrap when the request needs several memory read workflows.

Requires Python 3.11+ and the repository shared helpers.
