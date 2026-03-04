# memory-retrieve

Deterministic, grep-first memory retrieval skill for `~/.config/codex-agents/memory`.

## Files
- `SKILL.md`: skill definition and behavior contract
- `scripts/retrieve.sh`: executable retrieval script

## Purpose
Fetch minimal, relevant memory context before planning or architecture recommendations.

## Usage
```bash
./scripts/retrieve.sh "<query>" \
  [--scopes decisions,projects,patterns,knowledge,logs] \
  [--max-items N] \
  [--since YYYY-MM-DD] \
  [--project name]
```

From repo root:
```bash
skills/memory-retrieve/scripts/retrieve.sh "codex skills symlink"
```

## Options
- `--scopes`: comma-separated subset of `decisions,projects,patterns,knowledge,logs`
- `--max-items`: max evidence entries to emit (default `7`, hard cap `12`)
- `--since`: date filter for `logs` and `projects` (`YYYY-MM-DD`)
- `--project`: boost matches under `projects/<name>/`
- `-h`, `--help`: show help

## Output Contract
The script prints markdown with:
1. `## Retrieved Context` (short bullet summary)
2. `## Evidence` (numbered items with path, line window, relevance reason, excerpt)

## Ranking
Cross-scope priority:
1. `decisions`
2. `projects`
3. `patterns`
4. `knowledge`
5. `logs`

Within scope:
- heading matches rank above body matches
- exact query hits rank above keyword-only matches
- newer files rank above older files

## Safety
- Excerpts are minimally redacted for obvious secret patterns.
- Script is read-only for memory files.

## Examples
```bash
# Architecture continuity
skills/memory-retrieve/scripts/retrieve.sh \
  "how are skills and symlinks managed" \
  --scopes decisions,patterns

# Project continuity
skills/memory-retrieve/scripts/retrieve.sh \
  "current status and next steps" \
  --scopes projects,decisions \
  --project codex-agents \
  --since 2026-03-01
```

## Verification
```bash
# Help
skills/memory-retrieve/scripts/retrieve.sh --help

# Invalid scope (expects non-zero exit)
skills/memory-retrieve/scripts/retrieve.sh "status" --scopes nope

# Real query
skills/memory-retrieve/scripts/retrieve.sh "codex-agents current status"
```
