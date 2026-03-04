---
name: workflow-plan
description: Generate a deterministic execution plan artifact with constraints, acceptance criteria, verification, and rollback, then link it into project continuity.
---

# workflow-plan

## Purpose
Turn planning into a runnable, reviewable artifact with explicit verification and rollback.

This skill exists to prevent:
- hand-wavy plans without executable steps
- missing rollback strategy for risky work
- plan artifacts that are not linked to project continuity

## Memory Root
Default memory root: `~/.config/codex-agents/memory`

Plan targets:
- project mode: `memory/projects/<project>/plans/YYYY-MM-DD-<slug>.md`
- pattern mode: `memory/patterns/<slug>-plan.md`

## When to Use
Invoke when:
- the user asks for a plan that should be executed and tracked
- work has operational risk and needs verification + rollback
- project work needs durable next actions

## Inputs
Required:
- `goal`: one-line objective

Project mode (default):
- `project` is required unless `--to-pattern` is set

Optional:
- `title`
- `constraints` (bullets/newlines/comma-separated)
- `acceptance-criteria` (bullets/newlines/comma-separated)
- `date` (YYYY-MM-DD)
- `time` (HH:MM)
- `allow-redact` (override when high-confidence secrets are detected)

## Output (Contract)
The skill:
- writes one plan markdown file
- in project mode, appends a project-log pointer via `project-update`
- returns:
  - created plan path (relative)
  - plan heading
  - pointer update status (project mode)
  - warnings/redactions

Rules:
- deterministic section order
- collision-safe filenames (`-2`, `-3`, ...)
- strict secret policy on write inputs

## Plan Schema (Required)
- `# <title>`
- `Date: YYYY-MM-DD`
- `Project: <project>` (project mode only)
- `Goal: <goal>`
- `## Constraints`
- `## Acceptance Criteria`
- `## Execution Steps`
- `## Verification`
- `## Rollback`
- `## Risks`

## Secret Policy
- high-confidence findings: block write by default
- low-confidence findings: redact and continue
- `--allow-redact` allows blocked writes to proceed with redactions

## Implementation
Primary entrypoint:
- `scripts/plan.sh --goal "<goal>" --project "<project>" [--title "<title>"] [--constraints "<items>"] [--acceptance-criteria "<items>"] [--date YYYY-MM-DD] [--time HH:MM] [--allow-redact]`
- `scripts/plan.sh --goal "<goal>" --to-pattern [--title "<title>"] [--constraints "<items>"] [--acceptance-criteria "<items>"] [--date YYYY-MM-DD] [--time HH:MM] [--allow-redact]`
