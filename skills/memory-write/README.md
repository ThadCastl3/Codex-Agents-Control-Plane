# memory-write

Deterministic write gateway for persistent agent memory in `~/.config/codex-agents/memory`.

## Files
- `SKILL.md`: behavior contract and storage rules
- `scripts/write.sh`: executable write entrypoint

## Purpose
Write durable memory with strict schemas, append-only rules, and secret redaction so entries remain searchable, auditable, and reversible in git.

## Usage
```bash
./scripts/write.sh --type <type> --title "<title>" \
  [--body "<text>"] \
  [--project "<name>"] \
  [--status "<status>"] \
  [--next "<items>"] \
  [--tags "<t1,t2>"] \
  [--date YYYY-MM-DD]
```

From repo root:
```bash
skills/memory-write/scripts/write.sh --type log --title "Linked ~/.codex/skills to repo"
```

## Types
- `log`
- `decision`
- `project`
- `knowledge`
- `pattern`

## Storage Behavior
- `log`: appends to `memory/logs/YYYY/MM-DD.md`
- `decision`: creates `memory/decisions/YYYY-MM-<slug>.md` (one decision per file, collision-safe suffix)
- `project`: ensures `memory/projects/<project>/overview.md`; appends to `memory/projects/<project>/log.md`
- `knowledge`: creates/updates `memory/knowledge/<slug>.md`
- `pattern`: creates/updates `memory/patterns/<slug>.md`

## Append-Only Rules
- Never overwrites existing content (except append-only writes and index link appends).
- Decision files are immutable by convention: new decision => new file.

## Index Maintenance
When new `project`, `knowledge`, or `pattern` docs are created, the script appends discoverability links to:
- `memory/index.md` under `## Entries` (created if missing)

## Secret Handling
Before writing, content is scanned and sensitive values are redacted (for example: bearer tokens, API key-style strings, private key blocks, credential assignments).

Output includes:
- a `## Redactions` section
- recommendation to store secrets in env vars or secret managers when redactions occur

## Output Contract
Every run prints markdown with:
1. `## Memory Write Report`
2. `## Files Written`
3. `## Summary`
4. `## Redactions`

## Examples
```bash
# 1) Log capture
skills/memory-write/scripts/write.sh \
  --type log \
  --title "Linked ~/.codex/skills to repo" \
  --body "Symlinked ~/.codex/skills -> ~/.config/codex-agents/skills for git-backed state." \
  --tags "codex,symlink"

# 2) Decision record
skills/memory-write/scripts/write.sh \
  --type decision \
  --title "Files-first memory store" \
  --body "Use repo-backed markdown memory with append-only conventions."

# 3) Project update
skills/memory-write/scripts/write.sh \
  --type project \
  --project "codex-agents" \
  --title "Implemented memory-retrieve and memory-write definitions" \
  --status "in progress" \
  --next "Implement retrieve.sh,Implement write.sh,Add doctor checks"
```

## Verification
```bash
# Help
skills/memory-write/scripts/write.sh --help

# Invalid type (expects non-zero exit)
skills/memory-write/scripts/write.sh --type nope --title "x"

# Missing project for type=project (expects non-zero exit)
skills/memory-write/scripts/write.sh --type project --title "x"

# Valid write
skills/memory-write/scripts/write.sh \
  --type knowledge \
  --title "Token handling" \
  --body "Never commit credentials."
```
