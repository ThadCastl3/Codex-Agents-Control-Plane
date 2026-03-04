---
name: context-bootstrap
description: Mandatory bootstrap for non-trivial tasks. Loads agent context by running decision-check, project-status, and memory-retrieve against ~/.config/codex-agents/memory and returns constraints, project state, and relevant patterns before recommendations.
---

# context-bootstrap

## Purpose
Enforce deterministic context loading before non-trivial work so recommendations and artifacts reflect existing decisions, project state, and reusable patterns.

This skill exists to prevent:
- skipping existing constraints
- missing project continuity
- re-solving problems that already have runbooks/patterns

## When to Use (Mandatory)
Run this skill before responding to non-trivial requests, including:
- plans and architecture recommendations
- debugging ongoing systems
- continuation of prior work
- convention/process changes

Skip only when the task is:
- purely conceptual and unrelated to local system state
- trivial formatting/rewriting
- a one-off standalone example with no local-state interaction

## Inputs
Required:
- `query`: request-derived query string

Optional:
- `project`: explicit project hint
- `since`: YYYY-MM-DD filter for recent context
- `max-items`: max evidence/context entries (default 7, hard cap 12)
- `max-updates`: max project updates (default 5, hard cap 10)
- `min-confidence`: low|medium|high for decision checks (default medium)
- `scopes`: scopes for memory retrieval (default decisions,projects,patterns,knowledge,logs)

## Output (Contract)
Output must begin with:

## Context

Return one compact markdown block with:
1) `Applicable constraints` (deduplicated)
2) `Current project status`
3) `Relevant patterns`
4) `Evidence` (memory-relative paths)

Rules:
- Prefer concise bullets over long excerpts.
- If no decisions apply, include `No relevant decision found.`
- Include only evidence paths actually returned by source skills.

## Project Inference
If `--project` is not provided:

1) Search `memory/projects/` for folder names matching normalized query tokens.
2) Ignore query tokens shorter than 3 characters.
3) If exactly one match is found, treat it as the project.
4) If multiple matches exist, skip `project-status`.
5) If none exist, skip `project-status`.

## Constraint Deduplication
Constraints are duplicates when normalized text matches (trimmed, collapsed whitespace, case-insensitive).

When duplicates exist, preserve priority by keeping first occurrence from decision-check ordering, which already prefers:
1) newer decisions
2) decisions with `Status: accepted`

## Failure Handling
If any source skill fails:
- continue with remaining sources
- include a failure note in `Context` output
- never abort bootstrap

Failure notes must be sanitized and include only:
- `skill=<name> exit_code=<n> failed`

## Output Ordering
Sections must appear in this order:
1) `Applicable constraints`
2) `Current project status`
3) `Relevant patterns`
4) `Evidence`

## Implementation
Primary entrypoint:
- `scripts/bootstrap.sh`

Execution order:
1) Run `decision-check`
2) Determine project (explicit or inferred)
3) Run `project-status` if project identified
4) Run `memory-retrieve`

Merge outputs into the `Context` block.
Do not print raw outputs from source skills.
Only summarized results should appear.
