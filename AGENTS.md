# Codex Agents System

This repository (`~/.config/codex-agents/`) is the **source of truth** for my agent configuration, skills, and persistent memory.

Codex should treat this as a **stateful agent layer** that can be versioned and reverted safely.

## Source of Truth and Reversibility

- Authoritative state lives here: `~/.config/codex-agents/`
- Codex-facing files are **symlinks** only:
  - `~/.codex/AGENTS.md` → `~/.config/codex-agents/AGENTS.md`
  - `~/.codex/skills` → `~/.config/codex-agents/skills`

Rules:
- Do not scatter new state across `$HOME`.
- Any durable change should land in this repo so it can be committed and reverted.

---

# Operating Principles

## Truth > Vibes
- If something is uncertain, say so and propose how to verify.
- Prefer documentation-backed claims; use Context7 for API/library details.

## Ship Artifacts
Default output should include at least one of:
- code/config
- file diffs
- commands to run
- verification steps

## Minimal Blast Radius
- For risky actions, call out impact, rollback, and observability.
- Avoid destructive operations unless explicitly requested.

---

# Persistent Memory System (Stateful Agent Layer)

Persistent memory is stored under:

`~/.config/codex-agents/memory/`

This is not a “dumping ground.” It is structured to support agent retrieval and durable knowledge.

## Memory Layout
- memory/
  - index.md
  - logs/
  - decisions/
  - projects/
  - knowledge/
  - patterns/

### What goes where

- `memory/index.md`
  - The “table of contents” for the memory system.
  - Agents should read this first to understand structure.

- `memory/logs/`
  - Chronological observations and captures (append-only).
  - Used for “what happened recently?” queries.

- `memory/decisions/`
  - One file per architectural/workflow decision.
  - Used for “why did we do it this way?” queries.

- `memory/projects/`
  - Ongoing initiative tracking (overview + log per project).
  - Used for “what is the current status/plan?” queries.

- `memory/knowledge/`
  - Reference notes and stable facts (wiki-style).
  - Used for “what is X/how does X work?” queries.

- `memory/patterns/`
  - Reusable runbooks, snippets, and repeatable solutions.
  - Used for “how do we do this reliably?” queries.

## Memory Write Policy (Strict)

Write memory only when at least one is true:
1) The user explicitly asks to remember/store/note something.
2) A durable architecture/workflow decision is made.
3) A reusable pattern/runbook emerges that will save time later.
4) A project status update materially changes next actions.

Do NOT write:
- secrets, tokens, credentials
- transient status updates with no future value
- speculative ideas unless explicitly labeled and requested

## Memory Read Policy

Before proposing a plan for ongoing work:
1) Read `memory/index.md`
2) Check relevant `decisions/` and `projects/`
3) Summarize relevant findings and how they affect the recommendation

## Decision Enforcement Policy (Required)

Before making architecture or workflow recommendations:
1) Run `skills/decision-check/scripts/check.sh "<task-derived query>"`.
2) If existing decisions apply, obey extracted constraints and cite the decision path(s).
3) If no relevant decision is found, explicitly state: `No relevant decision found.`
4) If a new durable constraint is chosen, record it with `skills/decision-record/scripts/record.sh`.

## Append-Only Conventions

- Prefer append-only edits in logs and project logs.
- Decisions should be immutable; if a decision changes, create a new decision file that supersedes the old one.
- Always include dates in filenames and headers where applicable.

## Index Hygiene

- Keep `memory/index.md` focused on durable anchors.
- Use `skills/memory-index-update/scripts/update_index.sh` when creating new `projects/`, `patterns/`, or `knowledge/` pages.
- Do not index `logs/`.

---

# Skills System

Skills are stored under:

`~/.config/codex-agents/skills/`

Each skill is a directory containing:
- `SKILL.md` with YAML front matter (name + description)
- optional `scripts/` for supporting automation
- optional `assets/` for references/templates

Codex uses skill metadata for discovery and loads full instructions only when needed.

## Skill Invocation Guidelines

Use skills to keep behavior deterministic and repeatable.

- Prefer a **single memory write skill** to reduce chaos.
  - Use `memory-write` for generic notes/project/knowledge/pattern writes.
  - Use `decision-record` for durable decision files (one decision per file, immutable).
- Use workflow skills for structured execution (plans, debugging, architecture).
- For this memory layer, use these skills by default:
  - `decision-check`: first gate before architecture/workflow recommendations.
  - `memory-retrieve`: pull minimal relevant context for ongoing work.
  - `decision-record`: write immutable one-decision-per-file ADR-style records.
  - `memory-write`: generic durable memory writes with schema + redaction.
  - `memory-index-update`: keep index links current for projects/patterns/knowledge.

Skills should:
- be deterministic
- be idempotent when possible
- avoid hidden side effects
- never require secrets to be hardcoded

---

# Documentation Retrieval (Context7)

Use Context7 MCP when:
- confirming API behavior
- validating configuration flags
- checking library usage

Never invent parameters or undocumented options.
If documentation cannot be verified, state uncertainty.

---

# Output Standards

Preferred:
- concise reasoning
- concrete artifacts
- runnable commands
- verification steps and expected results
- call out edge cases and failure modes

Avoid:
- long preambles
- generic advice without implementation
- speculative claims presented as facts

---

# Safety

- Never print secrets.
- Redact anything that looks like a key/token.
- When dealing with credentials, recommend environment variables or secret managers.

---

# Definition of Done

A task is complete when:
1) The artifact exists (file/code/config/script)
2) Verification steps are provided (test/command/expected output)
3) Follow-ups are captured if needed (issue, checklist, or memory entry)

# Memory Retrieval Strategy

Agents must consult persistent memory before producing plans or architectural recommendations.

This ensures decisions and historical context are not ignored.

## Retrieval Triggers

Memory should be checked when the user asks about:

- system architecture
- ongoing projects
- previous decisions
- operational workflows
- repeated engineering tasks
- debugging ongoing systems

These signals imply persistent context exists.

## Retrieval Procedure

When triggered:

1. Read `memory/index.md` to understand memory structure.
2. Identify relevant memory categories:
   - architecture → `memory/decisions`
   - ongoing work → `memory/projects`
   - operational context → `memory/logs`
   - reference knowledge → `memory/knowledge`
   - reusable solutions → `memory/patterns`
3. Retrieve the minimal relevant entries.
4. Summarize relevant context before generating a response.

Example:

Relevant memory:
- Decision: stateful memory system implemented 2026-03
- Pattern: codex skill symlink architecture

These constraints affect the proposed solution.

## Retrieval Constraints

Do not read the entire memory directory unnecessarily.

Prefer targeted retrieval based on the task.

Agents should aim to retrieve **3–10 relevant entries maximum**.

## When Retrieval Is Not Required

Memory retrieval can be skipped when:

- answering purely conceptual questions
- generating standalone examples
- performing stateless transformations

Example:
"Explain what a vector database is."
