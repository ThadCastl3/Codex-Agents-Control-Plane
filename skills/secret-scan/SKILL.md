---
name: secret-scan
description: Scan text or files before memory writes or sensitive output.
---

# Secret Scan

Use `scripts/scan.sh` for this workflow. Read [the contract](references/contract.md) for inputs, output, schema, and advanced options before invoking it.

Write mode blocks high-confidence findings unless `--allow-redact` is explicitly supplied. Low-confidence findings are redacted. Read mode redacts without blocking. Exit 0 means pass/redacted; 3 means blocked; 2 means invalid input or unavailable runtime. Do not pass credentials as literal command arguments; prefer stdin.

Requires Python 3.11+ and the repository shared helpers.
