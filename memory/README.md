# Memory Operations Notes

This directory stores durable, agent-facing memory for continuity across sessions.

## Layout and Naming

- `logs/`: append-only chronological captures; prefer `YYYY/MM-DD.md` via write skills.
- `decisions/`: immutable one-decision-per-file records; date-prefixed filenames.
- `projects/`: one directory per project with `overview.md` and append-only `log.md`.
- `knowledge/`: stable reference notes; topic slug filenames.
- `patterns/`: reusable runbooks/procedures; slug filenames.

## Cadence

- Write logs when operational context changes materially.
- Write project updates when status/next actions change.
- Write decisions when durable constraints are chosen.
- Write patterns/knowledge only when reuse value is clear.

## Index Policy

- `index.md` is for durable anchors only.
- Index only `projects/`, `patterns/`, and `knowledge/`.
- Never add `logs/` entries to `index.md`.
- Prefer `skills/memory-index-update/scripts/update_index.sh` for index changes.
