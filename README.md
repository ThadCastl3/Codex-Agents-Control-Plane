# Codex Agents

`~/.config/codex-agents` is a files-first, git-backed state layer for Codex.

It centralizes:
- agent operating policy
- reusable skills
- persistent memory

The goal is deterministic behavior with safe rollback.

## Why This Repo Exists

Without a state layer, agents tend to:
- repeat decisions
- lose project continuity
- produce inconsistent runbooks
- drift from agreed constraints

This repository fixes that by making durable state explicit, structured, and versioned.

## Source of Truth and Symlink Model

Authoritative state lives in this repo.

Codex-facing paths should be symlinks:
- `~/.codex/AGENTS.md` -> `~/.config/codex-agents/AGENTS.md`
- `~/.codex/skills` -> `~/.config/codex-agents/skills`

This keeps Codex integration stable while all real state stays git-managed.

## Repository Layout

```text
~/.config/codex-agents/
├── AGENTS.md
├── README.md
├── lib/
│   └── secret_scan.sh
├── memory/
│   ├── README.md
│   ├── index.md
│   ├── logs/
│   ├── decisions/
│   ├── projects/
│   ├── knowledge/
│   └── patterns/
├── skills/
│   ├── decision-check/
│   ├── context-bootstrap/
│   ├── decision-record/
│   ├── memory-index-update/
│   ├── memory-retrieve/
│   ├── memory-write/
│   ├── project-status/
│   ├── project-update/
│   ├── workflow-plan/
│   ├── runbook-create/
│   ├── secret-scan/
│   ├── security-best-practices/
│   └── gh-address-comments/
├── bin/
│   ├── doctor.sh
│   └── install.sh
└── templates/
```

## Operating Model

### 1) Read Before Recommend

Before architecture/workflow recommendations:
1. Read `memory/index.md`.
2. Check relevant decisions and project context.
3. Summarize constraints before proposing changes.

### 2) Decision Enforcement

Use `decision-check` before architecture/workflow changes.

If relevant decisions exist, they are constraints, not suggestions.

### 3) Append-Only Discipline

- logs and project logs: append-only
- decisions: immutable (new file when superseding)
- index: additive, minimal diff, no aggressive reordering

### 4) Automatic Index Hygiene

Index discoverability is now default behavior at creation time:
- `workflow-plan --to-pattern`: auto-registers the new pattern plan in `memory/index.md` (`## Patterns`)
- `project-update`: when first scaffolding `overview.md`, auto-registers under `## Projects`
- `memory-write`: when creating new `project`, `knowledge`, or `pattern` docs, auto-registers under the mapped section

All of the above route index writes through:
- `skills/memory-index-update/scripts/update_index.sh`

If automatic index update cannot run, scripts print the exact fallback command to execute manually.

### 5) Strict Secret Policy

All write-side memory scripts enforce shared secret scanning.

Default behavior:
- high-confidence secrets: block write
- low-confidence secret-like content: redact and continue

Override (explicit):
- `--allow-redact` allows blocked writes to proceed with in-place redaction

Shared scanner library:
- `lib/secret_scan.sh`

## Skill Catalog

Each skill has:
- `SKILL.md` contract
- optional `scripts/` executables

Primary memory/continuity skills:

| Skill | Purpose | Script |
|---|---|---|
| `context-bootstrap` | Mandatory first pass for non-trivial tasks; orchestrates decision-check + project-status + memory-retrieve into one compact Context block | `skills/context-bootstrap/scripts/bootstrap.sh` |
| `decision-check` | Find applicable prior decisions before recommending changes | `skills/decision-check/scripts/check.sh` |
| `decision-record` | Create immutable one-decision-per-file records | `skills/decision-record/scripts/record.sh` |
| `memory-retrieve` | Pull minimal relevant memory context | `skills/memory-retrieve/scripts/retrieve.sh` |
| `memory-write` | Generic structured memory writer with automatic index registration for new anchors | `skills/memory-write/scripts/write.sh` |
| `memory-index-update` | Keep `memory/index.md` discoverable and idempotent | `skills/memory-index-update/scripts/update_index.sh` |
| `project-status` | Summarize project state from overview + log | `skills/project-status/scripts/status.sh` |
| `project-update` | Append structured project log updates and auto-index first-time project scaffolding | `skills/project-update/scripts/update.sh` |
| `workflow-plan` | Generate executable plan artifacts with verification + rollback (auto-index in `--to-pattern` mode) | `skills/workflow-plan/scripts/plan.sh` |
| `runbook-create` | Create reusable pattern/runbook docs and index them | `skills/runbook-create/scripts/create.sh` |
| `secret-scan` | Standalone pass/redact/block scanner utility | `skills/secret-scan/scripts/scan.sh` |

Additional utility skills:
- `security-best-practices`
- `gh-address-comments`

## Memory Data Model

Memory root: `memory/`

- `README.md`: operational conventions for cadence, naming, and index policy
- `index.md`: table of contents for durable anchors
- `logs/`: chronological notes
- `decisions/`: architectural/workflow constraints
- `projects/`: continuity (`overview.md` + `log.md` per project)
- `knowledge/`: stable reference notes
- `patterns/`: reusable procedures/runbooks

## Quickstart

### 1) Install symlinks and run health checks

```bash
bin/install.sh
```

`bin/install.sh` runs `bin/doctor.sh` by default after symlink reconciliation.

### 2) Run doctor explicitly (optional but recommended in CI and troubleshooting)

```bash
bin/doctor.sh
```

### 3) Manual fallback symlink commands (if needed)

```bash
ln -sfn ~/.config/codex-agents/AGENTS.md ~/.codex/AGENTS.md
ln -sfn ~/.config/codex-agents/skills ~/.codex/skills
```

### 4) Validate shell scripts

```bash
bash -n \
  bin/install.sh \
  bin/doctor.sh \
  lib/secret_scan.sh \
  skills/secret-scan/scripts/scan.sh \
  skills/memory-retrieve/scripts/retrieve.sh \
  skills/memory-write/scripts/write.sh \
  skills/decision-check/scripts/check.sh \
  skills/decision-record/scripts/record.sh \
  skills/project-status/scripts/status.sh \
  skills/project-update/scripts/update.sh \
  skills/memory-index-update/scripts/update_index.sh \
  skills/workflow-plan/scripts/plan.sh \
  skills/runbook-create/scripts/create.sh
```

### 5) Run in temp memory for safe testing

```bash
TMP_ROOT="$(mktemp -d)"
export MEMORY_ROOT="$TMP_ROOT/memory"
mkdir -p "$MEMORY_ROOT"
```

## Operator Workflow

- Use `bin/install.sh` to reconcile expected symlinks with backup-and-replace safety.
- Use `bin/doctor.sh` to detect drift; it exits non-zero when checks fail.
- Prefer `bin/install.sh --dry-run` before first-time setup on unknown machines.
- Use `bin/install.sh --skip-doctor` only when sequencing setup manually.

## Common Workflows

### Check decisions before proposing architecture

```bash
skills/decision-check/scripts/check.sh "skills directory and symlinks"
```

### Retrieve targeted context

```bash
skills/memory-retrieve/scripts/retrieve.sh "codex-agents current status" \
  --scopes projects,decisions \
  --project codex-agents
```

### Create a project execution plan

```bash
skills/workflow-plan/scripts/plan.sh \
  --goal "Implement deterministic retrieval ranking" \
  --project "codex-agents" \
  --constraints "append-only logs,minimal diffs" \
  --acceptance-criteria "tests pass,rollback documented"
```

Pattern mode (`--to-pattern`) also updates `memory/index.md` automatically.

### Append project continuity update

```bash
skills/project-update/scripts/update.sh \
  --project "codex-agents" \
  --title "Implemented workflow-plan" \
  --status "in progress" \
  --notes "Added script and report contract" \
  --next "Implement runbook-create,Run smoke tests"
```

If this is the first update for a project and scaffolding is created, index registration is automatic.

### Write durable knowledge with automatic index registration

```bash
skills/memory-write/scripts/write.sh \
  --type knowledge \
  --title "Token handling" \
  --body "Prefer env vars or secret manager; never commit credentials."
```

New `knowledge`/`pattern`/`project` anchors are auto-indexed through `memory-index-update`.

### Create a reusable runbook and index it

```bash
skills/runbook-create/scripts/create.sh \
  --title "Release Cutover" \
  --when-to-use "When promoting a tested candidate to production" \
  --steps "Validate artifacts,Deploy canary,Promote" \
  --verification "Smoke tests pass,No elevated error rate" \
  --failure-modes "Canary fails,Rollback incomplete"
```

### Scan text for secrets before writing

```bash
skills/secret-scan/scripts/scan.sh --text "token=abc123" --mode write
```

## Secret Enforcement Details

Exit code conventions for `secret-scan`:
- `0`: pass or redacted
- `3`: blocked
- `2`: argument/validation error

Write-side scripts inherit the same policy and support `--allow-redact`.

## Contribution Guidelines

1. Keep behavior deterministic and auditable.
2. Favor append-only updates for logs/project logs.
3. Never silently mutate prior decision files.
4. Keep index updates idempotent and minimal-diff.
5. Use relative memory paths in script reports.
6. Do not commit secrets; redaction is required.

## Git Workflow

Typical cycle:

```bash
git status
git add <files>
git commit -m "feat(...): ..."
```

Rollback is straightforward because state is file-based and versioned.

## Relationship to `AGENTS.md`

`AGENTS.md` is the runtime operating policy for agents.

`README.md` is the human/operator guide for understanding and contributing to this repository.

If there is ambiguity, follow `AGENTS.md` for behavior and update this README accordingly.
