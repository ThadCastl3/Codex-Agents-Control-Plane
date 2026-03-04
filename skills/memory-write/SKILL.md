---
name: memory-write
description: Write to the files-first memory store (~/.config/codex-agents/memory) using strict schemas and append-only rules to keep agent memory reliable and reversible.
---

# memory-write

## Purpose
Persist durable knowledge and state updates in a way that remains:
- searchable (grep/rg)
- auditable (git diff friendly)
- deterministic (repeatable writes)
- low-noise (strict triggers)

This skill exists to prevent:
- memory sprawl
- inconsistent formatting
- overwriting history
- leaking secrets into persistent storage

## Memory Root
Default memory root: `~/.config/codex-agents/memory`

Expected layout:
- `index.md`
- `logs/`
- `decisions/`
- `projects/`
- `knowledge/`
- `patterns/`

## When to Use (Write Triggers)
Invoke this skill only when at least one is true:
1) The user explicitly asks to remember/store/note something.
2) A durable decision is made (architecture/workflow/convention).
3) A project update materially changes next actions.
4) A reusable pattern/runbook emerges that will matter again.

Do NOT write:
- secrets/tokens/credentials
- transient notes with no future value
- speculative ideas unless explicitly requested and labeled

## Inputs
Required:
- `type`: one of `log`, `decision`, `project`, `knowledge`, `pattern`
- `title`: short descriptive title

Optional (depends on type):
- `body`: freeform text (bullets or paragraphs)
- `project`: project name/slug for `type=project`
- `status`: one-line status for `type=project`
- `next`: next actions (bullets or comma-separated) for `type=project`
- `tags`: comma-separated tags (stored as `Tags:` line)
- `date`: YYYY-MM-DD (default today)

## Output (Contract)
The skill returns:
- the file path(s) written
- a short summary of what was written
- any redactions performed (if applicable)

Rules:
- Never overwrite existing content except to append or to update index links.
- All entries must be timestamped.
- Keep each write small and structured.

## Storage Rules by Type

### type=log
Location:
- `memory/logs/YYYY/MM-DD.md`

Append format:
- `## YYYY-MM-DD HH:MM — <title>`
- body as bullets (preferred) or short paragraph
- optional `Tags: ...`

Use for:
- chronological captures
- operational notes that might matter later

### type=decision
Location:
- `memory/decisions/YYYY-MM-<slug>.md` (one decision per file)

Format:
- `# <title>`
- `Date: YYYY-MM-DD`
- `Status: accepted` (default)
- `Tags: ...` (optional)
- `## Context`
- `## Decision`
- `## Consequences`
- `## Tradeoffs`
- `## Follow-ups`

Rules:
- Do not mutate old decision files.
- If changing a decision, create a new decision file that references `Supersedes: <path>`.

### type=project
Location:
- `memory/projects/<project>/overview.md`
- `memory/projects/<project>/log.md`

Write behavior:
- If project folder does not exist, create it and create `overview.md` with:
  - `# <project>`
  - `Owner: (optional)`
  - `Goal:`
  - `Constraints:`
- Append to `log.md`:
  - `## YYYY-MM-DD HH:MM — <title>`
  - `Status: <status>`
  - `Notes:` bullets
  - `Next:` checklist bullets

Rules:
- Append-only to log.md.
- Keep entries focused on changes and next actions.

### type=knowledge
Location:
- `memory/knowledge/<topic>/<slug>.md` or `memory/knowledge/<slug>.md`

Format:
- `# <title>`
- `Date: YYYY-MM-DD`
- `Tags: ...` (optional)
- content is stable reference notes, not timeline

Use for:
- reference notes about tools, conventions, internal docs
- summaries that should persist

### type=pattern
Location:
- `memory/patterns/<slug>.md`

Format:
- `# <title>`
- `When to use:`
- `Steps:`
- `Verification:`
- `Failure modes:`
- `Notes:`
- `Tags: ...` (optional)

Use for:
- runbooks
- reusable snippets
- repeatable debugging procedures

## Index Maintenance
When a new project, pattern, or knowledge doc is created:
- ensure it is discoverable from `memory/index.md` by adding a short link entry if missing.
- do not reorder index aggressively; append new links.

## Secret Handling (Required)
Before writing:
- scan content for likely secrets (API keys, bearer tokens, private keys).
- if found:
  - redact the sensitive portion
  - note "REDACTED" in output
  - suggest storing secrets in env vars or a secret manager

## Implementation
Primary entrypoint:
- `scripts/write.sh --type <type> --title "<title>" [--body "<text>"] [--project "<name>"] [--status "<status>"] [--next "<items>"] [--tags "<t1,t2>"] [--date YYYY-MM-DD]`

The script should:
- create missing directories/files
- enforce schemas
- append safely
- return a markdown report to stdout

## Examples

### Example 1: Log capture
Write a short note about a configuration change:
- type: log
- title: "Linked ~/.codex/skills to repo"
- body: "Symlinked ~/.codex/skills -> ~/.config/codex-agents/skills for git-backed state."

### Example 2: Decision record
- type: decision
- title: "Files-first memory store"
- body: context/decision/consequences/tradeoffs/followups

### Example 3: Project update
- type: project
- project: "codex-agents"
- title: "Implemented memory-retrieve and memory-write definitions"
- status: "in progress"
- next: "Implement retrieve.sh,Implement write.sh,Add doctor checks"
