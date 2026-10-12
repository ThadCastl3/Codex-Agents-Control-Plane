---
name: memory-retrieve
description: Retrieve bounded evidence from structured memory for ongoing work.
---

# Memory Retrieve

Use `scripts/retrieve.sh` for this workflow. Read [the contract](references/contract.md) for inputs, output, schema, and advanced options before invoking it.

This is a read-only workflow. Do not expose sensitive values or modify source documents. Decision graph errors return 3; unavailable dependencies or invalid inputs return 2. Use context-bootstrap when the request needs several memory read workflows.

Requires Python 3.11+ and the repository shared helpers.
