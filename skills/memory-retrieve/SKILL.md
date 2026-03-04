---
name: memory-retrieve
description: Retrieve the minimum relevant context from the files-first memory store (~/.config/codex-agents/memory) to inform the current task, without over-reading.
---

# memory-retrieve

## Purpose
Provide stateful context to agents by pulling targeted, minimal excerpts from persistent memory before planning or recommending changes.

This skill exists to prevent:
- repeating decisions already made
- ignoring project context
- reinventing runbooks/patterns
- making architecture suggestions that conflict with constraints

## Memory Root
Default memory root: `~/.config/codex-agents/memory`

Expected layout:
- `index.md`
- `logs/`
- `decisions/`
- `projects/`
- `knowledge/`
- `patterns/`

## When to Use (Retrieval Triggers)
Invoke this skill when the user request involves any of:
- ongoing work / "continue where we left off"
- architecture / deployment / system design
- "what did we decide" / "how are we doing this"
- debugging an existing system
- anything that sounds like it has historical context or local conventions

Skip retrieval for:
- purely conceptual explanations
- standalone examples unrelated to user systems
- tasks explicitly marked as stateless

## Inputs
Required:
- `query`: natural language query, keywords, or filenames (e.g. "context7 mcp headers", "skills symlink", "codex-agents install")

Optional:
- `scopes`: comma-separated list restricting search:
  - `decisions`, `projects`, `patterns`, `knowledge`, `logs`
  - default: all (with priority order)
- `max_items`: maximum items to return (default 7, hard cap 12)
- `since`: date filter for logs/projects (YYYY-MM-DD). If provided, prefer entries on/after this date.
- `project`: project slug/name hint (e.g. "codex-agents") to bias results toward `projects/<project>/`.

## Output (Contract)
The skill returns:
1) A brief Retrieved Context summary (3-10 bullets max)
2) A list of Evidence items with:
   - file path
   - line ranges (or small excerpt)
   - why it's relevant

Rules:
- Prefer fewer, higher-quality items.
- Do not dump huge excerpts.
- Favor decisions and patterns over raw logs when applicable.

## Ranking Heuristic
Default priority when searching across scopes:
1) `decisions/` (most authoritative constraints)
2) `projects/` (current state + next actions)
3) `patterns/` (how we do things)
4) `knowledge/` (reference docs)
5) `logs/` (chronological noise; use sparingly)

Within a scope:
- prefer more recent files (by filename date or mtime if available)
- prefer matches in headings over body text
- prefer exact keyword matches over fuzzy

## Safety
- Do not surface secrets. If a match appears to contain keys/tokens, redact and note the file for manual review.
- Never modify files in this skill.

## Implementation
Primary entrypoint:
- `scripts/retrieve.sh "<query>" [--scopes decisions,projects,...] [--max-items N] [--since YYYY-MM-DD] [--project name]`

The script should:
- use `rg` if available; fallback to `grep`
- return a structured markdown report to stdout
- exit non-zero on invalid args, missing memory root, or internal failure

## Examples

### Example 1: Architecture question
Input:
- query: "how are we managing codex skills and symlinks"

Expected:
- search decisions + patterns first
- return link/excerpt from symlink decision/pattern docs

### Example 2: Project continuity
Input:
- query: "codex-agents current status"
- scopes: projects,decisions
- project: codex-agents

Expected:
- summarize last project log entry and current next steps
