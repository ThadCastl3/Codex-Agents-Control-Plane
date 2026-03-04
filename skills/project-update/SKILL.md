---
name: project-update
description: Append a structured update to ~/.config/codex-agents/memory/projects/<project>/log.md (and create overview.md/log.md if missing) so agents can reliably resume work.
---

# project-update

## Purpose
Keep project state current and machine-summarizable by appending structured updates to a project log.

This skill exists to:
- preserve continuity across sessions
- maintain a consistent log schema for retrieval/summarization
- ensure new projects get bootstrapped correctly (overview + log)

## Memory Root
`~/.config/codex-agents/memory`

Target directory:
- `memory/projects/<project>/`

Expected files:
- `overview.md`
- `log.md`

If missing:
- create project directory and minimal overview/log scaffolding

## When to Use
Invoke when:
- the user completes work or changes direction on a project
- the agent proposes a plan and needs to capture the updated next actions
- a blocker/risk appears that will matter later
- the user asks to "note the status / update the project"

Skip when:
- the update is trivial and has no future value

## Inputs
Required:
- `project`: project identifier (folder name or human name)
- `title`: short update title (e.g., "Defined memory-write schema")
- `status`: one-line status summary (e.g., "in progress", "blocked", "done")
- `notes`: bullets or paragraph describing what changed (keep concise)
- `next`: next actions as bullets or comma-separated list

Optional:
- `blockers`: blockers/risks as bullets or comma-separated list
- `tags`: comma-separated tags
- `date`: YYYY-MM-DD (default today)
- `time`: HH:MM (default current local time)

## Output (Contract)
The skill:
- appends exactly one new entry to `memory/projects/<project>/log.md`
- returns:
  - the updated log file path (relative to memory root)
  - the heading of the entry written
  - any scaffolding created (overview/log)

Rules:
- Append-only to log.md.
- Never rewrite or reorder existing entries.
- Keep entries small and structured.

## Log Entry Schema (Required)
Append entries in this format:

- `## YYYY-MM-DD HH:MM — <title>`
- `Status: <status>`
- `Tags: <tags>` (optional)
- `Notes:`
  - `- ...`
- `Next:`
  - `- [ ] ...`
- `Blockers:` (optional)
  - `- ...`

## Project Overview Scaffolding (If Missing)
If `overview.md` does not exist, create it with:

- `# <project>`
- `Goal:`
- `Constraints:`
- `Approach:`
- `Key Links:`

Do not invent content; leave fields blank if unknown.

## Secret Handling
Scan all fields before writing.
If a likely secret is detected:
- high-confidence findings: block write by default
- low-confidence findings: redact and continue
- `--allow-redact` overrides blocked writes and proceeds with redaction
- write `[REDACTED]` in place and return warnings in output

## Implementation
Primary entrypoint:
- `scripts/update.sh --project "<project>" --title "<title>" --status "<status>" --notes "<text>" --next "<items>" [--blockers "<items>"] [--tags "t1,t2"] [--date YYYY-MM-DD] [--time HH:MM] [--allow-redact]`

Script behavior:
- resolves `<project>` folder:
  - exact match under `memory/projects/`
  - else slugify input and use slug
- creates missing directory/files safely
- appends one well-formed entry
- outputs a short markdown report to stdout

## Examples

### Example 1
project: "codex-agents"
title: "Added decision-check and project-status skills"
status: "in progress"
notes: "Drafted SKILL.md specs; ready to implement scripts."
next: "Implement check.sh,Implement status.sh,Add doctor validation"
blockers: "None"

### Example 2
project: "codex-agents"
title: "Context7 MCP headers verified"
status: "done"
notes: "Validated env_http_headers mapping and confirmed env var propagation."
next: "Commit changes,Tag release"
tags: "mcp,context7"
