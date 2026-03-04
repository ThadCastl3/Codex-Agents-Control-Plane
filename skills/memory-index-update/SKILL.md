---
name: memory-index-update
description: Update memory/index.md with discoverable links when new projects, patterns, or knowledge pages are created, preventing memory sprawl from becoming invisible.
---

# memory-index-update

## Purpose
Keep `~/.config/codex-agents/memory/index.md` accurate and navigable as memory grows.

This skill exists to prevent:
- new memory pages being created but never referenced
- memory becoming undiscoverable to agents
- inconsistent index formatting across categories

## Memory Root
Default memory root: `~/.config/codex-agents/memory`

Primary target:
- `memory/index.md`

## When to Use
Invoke when:
- a new project folder is created under `memory/projects/<project>/`
- a new pattern is created under `memory/patterns/`
- a new knowledge page is created under `memory/knowledge/`

Skip when:
- updating log files under `memory/logs/`
- minor edits to existing indexed pages (unless the index entry is missing/stale)

## Inputs
Required:
- `change`: one of `add-project`, `add-pattern`, `add-knowledge`
- `path`: relative to memory root (preferred), e.g.
  - `projects/codex-agents/overview.md`
  - `patterns/codex-symlink-architecture.md`
  - `knowledge/codex/skills.md`
- `description`: short human-readable description (1 line)

Optional:
- `title`: display text for the link (default derived from file name/folder)
- `section`: override index section name (rare; default based on change)
- `date`: YYYY-MM-DD (default today)

## Output (Contract)
The skill:
- ensures `memory/index.md` exists
- inserts a bullet link under the correct section
- avoids duplicates (idempotent)
- returns:
  - whether an entry was added or already present
  - the updated section name
  - the exact link line inserted (if any)

Rules:
- Never reorder existing entries.
- Prefer appending new entries to the end of the section.
- If a required section is missing, create it with a standard header.

## Index Format (Standard)
`memory/index.md` should contain these top-level sections:

- `## Projects`
- `## Patterns`
- `## Knowledge`

Each entry should be a single bullet:

- `- [<title>](<relative-path>) — <description>`

Example:
- `- [Codex Agents](projects/codex-agents/overview.md) — Source-of-truth repo for skills + stateful memory.`

## Section Mapping
- `add-project` -> `## Projects`
- `add-pattern` -> `## Patterns`
- `add-knowledge` -> `## Knowledge`

## Duplicate Detection
An entry is considered existing if `memory/index.md` already contains:
- the exact relative path in a markdown link, or
- a bullet line with the same link target

If a matching path exists with a different description:
- do not overwrite automatically
- instead, add a second bullet only if the title differs significantly
- otherwise, return "already present" and suggest a manual edit

## Implementation
Primary entrypoint:
- `scripts/update_index.sh --change <add-project|add-pattern|add-knowledge> --path "<relative-path>" --description "<one line>" [--title "<title>"]`

The script should:
- validate path exists under memory root
- normalize to a relative path (no absolute paths in index)
- ensure sections exist
- add the link line if missing
- be safe and idempotent

## Examples

### Example 1: Add a pattern
- change: add-pattern
- path: patterns/memory-write-schema.md
- description: "Canonical schema and write rules for the memory-write skill."

### Example 2: Add a project
- change: add-project
- path: projects/codex-agents/overview.md
- description: "Stateful agent layer (skills + memory) managed under git."
