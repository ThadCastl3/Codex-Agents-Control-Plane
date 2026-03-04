---
name: decision-check
description: Check ~/.config/codex-agents/memory/decisions for relevant prior decisions before making architecture/workflow recommendations, returning applicable constraints or confirming none exist.
---

# decision-check

## Purpose
Prevent architectural drift and repeated debates by verifying whether a relevant decision already exists before proposing changes.

This skill exists to:
- enforce previously accepted constraints
- avoid contradicting earlier decisions
- surface rationale and tradeoffs that still apply

## Memory Root
`~/.config/codex-agents/memory`

Target directory:
- `memory/decisions/`

## When to Use
Invoke this skill before:
- architecture recommendations
- changes to repo layout, deployment patterns, tooling conventions
- any suggestion that could conflict with established decisions

Skip when:
- answering purely conceptual questions unrelated to the user's system
- tasks explicitly declared stateless

## Inputs
Required:
- `query`: a short topic or question, e.g.
  - "skills directory and symlinks"
  - "memory structure"
  - "context7 mcp auth headers"
  - "where should scripts live"

Optional:
- `max_items`: max decisions to return (default 5, hard cap 8)
- `min_confidence`: one of `low|medium|high` (default `medium`)
- `since`: YYYY-MM-DD (prefer decisions on/after this date when ties exist)

## Output (Contract)
The skill returns one of:

### Case A - No relevant decision found
- A single line: `No relevant decision found.`
- Optional: 1-3 suggestions for what to record if a new decision is about to be made.

### Case B - Existing decision(s) apply
- A header: `Existing decision(s) apply:`
- Up to `max_items` decision entries with:
  - relative path
  - title
  - date
  - status
  - extracted constraints (1-5 bullets)
  - supersedes / superseded-by if present
- A final section: `Constraints to obey:` (deduplicated bullets)
- Additive machine-consumer lines for each deduplicated constraint:
  - `CONSTRAINT: <text>`

Rules:
- Prefer fewer, higher-confidence matches.
- Do not dump entire decision files; extract only the most relevant lines.
- `CONSTRAINT:` lines are additive and do not replace human-readable bullets.
- If multiple decisions conflict:
  - prefer newer decisions
  - prefer decisions with `Status: accepted`
  - note the conflict explicitly

## Matching and Ranking (Deterministic)
Decisions are matched using:
1) filename and title match (highest weight)
2) headings match (`## Decision`, `## Context`, `## Why`)
3) body text match (lower weight)

Ranking priority:
- Status: accepted > proposed > deprecated
- Newer date > older date
- More query hits > fewer hits

Confidence levels:
- `high`: multiple hits across title/decision headings
- `medium`: solid hits in title or decision section
- `low`: only body/logical similarity (avoid unless requested)

## Constraint Extraction Rules
Constraints should be extracted primarily from:
- `## Decision`
- `## Consequences`
- `## Tradeoffs` (only if it imposes an operational constraint)

If extraction is ambiguous:
- paraphrase carefully and cite the decision section used

## Safety
- Do not output secrets if present in decision files.
- Redact likely keys/tokens.
- Never modify decision files.

## Implementation
Primary entrypoint:
- `scripts/check.sh "<query>" [--max-items N] [--min-confidence medium|high|low] [--since YYYY-MM-DD]`

Script behavior:
- searches `memory/decisions/` using `rg` if available, else `grep`
- reads only matching files
- extracts: title, date, status, and a few constraint lines
- outputs a concise markdown report

## Examples

### Example 1
query: "symlink skills into ~/.codex"
Expected: returns the symlink decision and constraints like:
- "Authoritative state in ~/.config/codex-agents"
- "Codex surface area should remain symlinks only"

### Example 2
query: "memory retrieval strategy"
Expected: returns decision(s) governing memory structure, retrieval triggers, and write rules.
