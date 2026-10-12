---
name: context-bootstrap
description: Load decisions and project context before non-trivial work on this system.
---

# Context Bootstrap

Use `scripts/bootstrap.sh` for this workflow. Read [the contract](references/contract.md) for inputs, output, schema, and advanced options before invoking it.

Run before non-trivial system work. It is the single read router for decisions, project state, and relevant memory. Use a task-derived query and an explicit project hint when known. A complete hook-provided bootstrap for the same task satisfies the requirement.

Treat source failure or invalid decision graphs as unavailable context. Report a successful empty search as `No relevant decision found.` Only effective accepted constraints are binding.

Requires Python 3.11+ and the repository shared helpers.
