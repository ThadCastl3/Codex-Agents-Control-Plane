---
name: project-status
description: Summarize the current state of a project from ~/.config/codex-agents/memory/projects/<project>/ by reading overview.md and log.md and returning goals, recent updates, next actions, and blockers.
---

# project-status

## Purpose
Provide project continuity so agents can pick up work without re-deriving context.

This skill exists to:
- quickly rehydrate project intent (goal + constraints)
- surface the most recent status and decisions
- list next actions and blockers clearly
- reduce context loss across sessions

## Memory Root
`~/.config/codex-agents/memory`

Target directory:
- `memory/projects/<project>/`

Expected files:
- `overview.md` (project intent + constraints)
- `log.md` (append-only chronological updates)

If missing:
- report what’s missing
- suggest creating a minimal overview/log (do not invent content)

## When to Use
Invoke when:
- user references a project by name
- user says "continue", "where were we", "status", "next steps"
- the agent is about to propose changes in an ongoing initiative

Skip when:
- the task is clearly unrelated to any ongoing project

## Inputs
Required:
- `project`: project identifier (folder name or human name)
  - examples: `codex-agents`, `bid-optimizer`, `perceptivity-pipelines`

Optional:
- `since`: YYYY-MM-DD
  - used to prefer log entries on/after this date
  - if omitted, default to "most recent entries"

Optional:
- `max_updates`: maximum log entries to include in the summary (default 5, hard cap 10)

## Output (Contract)
The skill returns a concise markdown brief containing:

1) **Project:** <project>
2) **Goal:** (from overview.md if present)
3) **Constraints:** (from overview.md if present)
4) **Current Status:** (from most recent log entry)
5) **Next Actions:** (aggregated from most recent 1-3 log entries)
6) **Blockers / Risks:** (explicitly listed or inferred only if clearly stated)
7) **Recent Updates:** (up to `max_updates` entries with date + one-liner)
8) **Evidence:** file paths + small excerpts/line ranges

Rules:
- Do not dump entire files.
- Prefer the most recent, most actionable info.
- If overview.md and/or log.md are missing, say so and return a "Create these files" suggestion.

## Parsing Rules (Deterministic)
- `overview.md`:
  - prefer extracting text from headings like `Goal`, `Constraints`, `Scope`, `Non-Goals`
  - if headings don’t exist, use the first 10-20 lines as "Goal/Context" excerpt

- `log.md`:
  - entries begin with `## YYYY-MM-DD` (or `## YYYY-MM-DD HH:MM`)
  - most recent entry is the latest matching header (prefer file order bottom-up)
  - for each entry, extract:
    - `Status:` line if present
    - `Next:` section bullets if present
    - `Blockers:` section bullets if present

## Safety
- Never write or modify project files in this skill.
- Redact secrets if found in excerpts.

## Implementation
Primary entrypoint:
- `scripts/status.sh "<project>" [--since YYYY-MM-DD] [--max-updates N]`

Script behavior:
- resolves the project directory via:
  - exact folder match under `memory/projects/`
  - fallback: slugify project input and try again
- reads overview.md/log.md if present
- outputs a structured markdown summary to stdout

## Examples

### Example 1
Input:
- project: "codex-agents"

Expected output:
- Goal: stateful memory + skills under git
- Current status: last log status
- Next actions: implement retrieve/write scripts, doctor validation, etc.

### Example 2
Input:
- project: "codex-agents"
- since: "2026-03-01"

Expected:
- focus recent updates after March 1
