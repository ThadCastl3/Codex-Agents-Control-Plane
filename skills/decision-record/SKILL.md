---
name: decision-record
description: Create a new, immutable decision document under ~/.config/codex-agents/memory/decisions using a strict schema (one decision per file), optionally superseding prior decisions.
---

# decision-record

## Purpose
Record durable architectural and workflow decisions in a consistent, auditable format so agents can:
- avoid repeating past debates
- respect existing constraints
- explain "why" a system is shaped the way it is

Decision records are intended to be immutable. If a decision changes, create a new decision that supersedes the old one.

## Memory Root
`~/.config/codex-agents/memory`

Target directory:
- `memory/decisions/`

## When to Use
Invoke when:
- making or revising architecture choices
- defining conventions that affect future work (naming, layout, tooling, security posture)
- choosing between alternatives with meaningful tradeoffs
- committing to a new operating constraint (e.g., "files-first memory only")

Skip when:
- capturing transient status updates (use logs/projects)
- brainstorming without commitment

## Inputs
Required:
- `title`: short, descriptive title (e.g., "Skills and AGENTS.md are symlinked into ~/.codex")
- `decision`: one sentence describing what we chose
- `context`: 1-6 bullets describing background and constraints
- `why`: 1-6 bullets explaining rationale
- `tradeoffs`: 1-8 bullets listing costs/risks/downsides
- `followups`: 0-10 items (bullets or comma-separated) for next actions

Optional:
- `supersedes`: relative path to a prior decision file (e.g. `decisions/2026-03-files-first-memory.md`)
- `status`: one of `accepted`, `proposed`, `deprecated` (default `accepted`)
- `tags`: comma-separated tags (stored as a single `Tags:` line)
- `date`: YYYY-MM-DD (default today)

## Output (Contract)
This skill creates exactly one new decision file and returns:
- `path`: relative path under memory root (e.g., `decisions/2026-03-skills-symlink-architecture.md`)
- `summary`: one line summary of the decision
- `links`: any referenced `supersedes` path

Rules:
- Never edits existing decision files.
- Filename is deterministic: `YYYY-MM-<slug>.md` based on title.
- If filename already exists, append a stable suffix: `-2`, `-3`, etc.

## Decision Document Schema (Required)
The generated decision doc must match this structure:

- `# <title>`
- `Date: YYYY-MM-DD`
- `Status: <status>`
- `Tags: <tags>` (optional)
- `Supersedes: <relative-path>` (optional)
- `## Context`
- `## Decision`
- `## Why`
- `## Tradeoffs`
- `## Follow-ups`

Formatting rules:
- Sections use `##` headings
- Bullets use `- `
- Keep content concise and specific
- No secrets in any section

## Secret Handling
Before writing, scan all content for likely secrets.
If found:
- high-confidence findings: block write by default
- low-confidence findings: redact and continue
- `--allow-redact` overrides blocked writes and proceeds with redaction
- include `[REDACTED]` in-place and return warnings in output

## Implementation
Primary entrypoint:
- `scripts/record.sh --title "<title>" --decision "<one sentence>" --context "<bullets>" --why "<bullets>" --tradeoffs "<bullets>" --followups "<items>" [--supersedes "<path>"] [--status accepted] [--tags "t1,t2"] [--date YYYY-MM-DD] [--allow-redact]`

Script behavior:
- creates directories if missing
- writes a single new file with the schema above
- does not require external dependencies
- returns a markdown report to stdout

## Examples

### Example 1 (New decision)
title: "Codex skills are symlinked into the state repo"
decision: "Use ~/.codex/skills -> ~/.config/codex-agents/skills symlink to keep skills git-managed."
context: "Need reversibility; avoid sprawl; Codex expects a stable skills directory."
why: "Git rollback; deterministic state; minimal Codex surface area."
tradeoffs: "Symlink resolution issues; must ensure install script is idempotent."
followups: "Add doctor checks,Document install/uninstall,Add memory-index entry"

### Example 2 (Superseding)
supersedes: "decisions/2026-03-files-first-memory.md"
