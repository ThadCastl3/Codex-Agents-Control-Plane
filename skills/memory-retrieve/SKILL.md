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
- `--explain` / `--debug`: include per-selected-file scoring breakdown (scope base, match components, recency, boosts/penalties, final score).
- `MEMORY_RETRIEVE_TRACE=1` (env var): print internal diagnostics to `stderr` (token mode/tokens, candidate pass counts by scope, supersedes index stats). No stdout schema changes.

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

Base scope weights:
- `decisions`: +120
- `projects`: +110
- `patterns`: +105
- `knowledge`: +70
- `logs`: +25

Intent-sensitive boosts:
- runbook intent (`how`, `steps`, `runbook`, `procedure`, `playbook`, `debug`, `triage`, `deploy`):
  - `patterns` +25, `logs` +10
- status intent (`status`, `next`, `continue`, `where were we`, `blocker`, `roadmap`):
  - `projects` +35, `logs` +10
- decision intent (`decision`, `why`, `policy`, `constraint`, `standard`, `convention`):
  - `decisions` +35

Within-file match scoring:
- title line (`# ...`) or filename hit: +60 per weighted hit
- section heading hit (`## ...`): +45
- decision-ish section hit (`Decision|Consequences|Constraints`): +55
- pattern-ish section hit (`Steps|Verification|Failure modes`): +55
- project-ish section hit (`Status|Next|Blockers`): +55
- normal body hit: +18
- exact token match: 1.0x
- prefix token match: 0.8x
- substring token match: 0.6x
- tokenization hierarchy (all tokens restricted to `[a-z0-9]+`, deduped in-order):
  - strict mode: tokens length `>=3` with stopwords removed
  - fallback mode (when strict is empty): tokens length `>=2`, no stopword removal
  - last-resort mode (when fallback is empty): longest normalized alnum token (`>=1`), otherwise normalized query with spaces removed
- candidate prefilter behavior:
  - strict mode: `rg -w` primary pass, then non-`-w` fallback pass only if needed
  - fallback/last-resort mode: non-`-w` pass directly
- body contribution cap: +60 per file
- total match contribution cap: +180 per file

Recency scoring (bucketed by file date/mtime):
- within 7 days: 100%
- within 30 days: 70%
- within 90 days: 40%
- older: low non-zero bucket (decisions retain higher old-age weight)
- scope maxima:
  - `logs`: +40
  - `projects`: +30
  - `decisions`: +20
  - `patterns`: +15
  - `knowledge`: +15

Decision-specific adjustments:
- `Status: accepted` +40
- `Status: proposed` +10
- `Status: deprecated` -50
- supersession signal penalty (small negative bias), computed from a one-time supersedes index prepass:
  - `-10` if this decision has a `Supersedes:` line
  - `-10` if this decision is superseded by another decision
  - lookup supports `Supersedes:` refs as relative path, basename, or basename without `.md` (including comma-separated refs)

Project bias:
- file under `projects/<project>/`: +50
- decisions/patterns/knowledge with project mention in title/headings: +20

Spam-control penalties:
- file > 500 lines with >80% match score from body text (`match_body` only): -30
- `logs/` file with >20 matched lines and no heading hits: -25

Selection rules:
- default `max_items=7` (hard cap 12)
- threshold:
  - default: `>=120`
  - logs: `>=80`
- diversity caps:
  - max 4 per scope
  - max 3 from `logs/`
  - max 3 from `knowledge/`
- force-include at least one `decisions/` result only when quality is sufficient:
  - candidate score meets threshold (`>=120`), or
  - candidate has title/filename/heading match (not body-only)
- final output order is deterministic by scope precedence, then score:
  1) decisions
  2) projects
  3) patterns
  4) knowledge
  5) logs

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
