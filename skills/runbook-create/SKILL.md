---
name: runbook-create
description: Create a deterministic reusable runbook/pattern under memory/patterns and register it in memory/index.md.
---

# runbook-create

## Purpose
Capture repeatable procedures as durable runbooks so future tasks are faster and less error-prone.

This skill exists to prevent:
- repeating the same troubleshooting/deploy steps from scratch
- runbooks that are not discoverable in memory/index.md
- inconsistent pattern schema across teams/sessions

## Memory Root
Default memory root: `~/.config/codex-agents/memory`

Target:
- `memory/patterns/<slug>.md` (suffix on collision)

## When to Use
Invoke when:
- a process repeats (deploy, debug, recovery, migration)
- a one-off procedure should become reusable
- operations need explicit failure-mode guidance

## Inputs
Required:
- `title`
- `when-to-use`
- `steps`
- `verification`
- `failure-modes`

Optional:
- `notes`
- `tags`
- `date` (YYYY-MM-DD)
- `allow-redact` (override when high-confidence secrets are detected)

## Output (Contract)
The skill:
- writes one runbook file under `memory/patterns/`
- invokes `memory-index-update` to register discoverability
- returns:
  - created file path (relative)
  - heading
  - index update result
  - warnings/redactions

Rules:
- deterministic section order
- collision-safe filenames (`-2`, `-3`, ...)
- strict secret policy on write inputs

## Runbook Schema (Required)
- `# <title>`
- `Date: YYYY-MM-DD`
- `Tags: ...` (optional)
- `## When to use`
- `## Steps`
- `## Verification`
- `## Failure modes`
- `## Notes` (optional)

## Secret Policy
- high-confidence findings: block write by default
- low-confidence findings: redact and continue
- `--allow-redact` allows blocked writes to proceed with redactions

## Implementation
Primary entrypoint:
- `scripts/create.sh --title "<title>" --when-to-use "<text>" --steps "<items>" --verification "<items>" --failure-modes "<items>" [--notes "<text>"] [--tags "t1,t2"] [--date YYYY-MM-DD] [--allow-redact]`
