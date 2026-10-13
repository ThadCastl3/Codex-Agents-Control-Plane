# Release Notes

## Unreleased

- Snapshot restore validates destinations before mutation and limits rollback
  to recorded changes, preserving external files behind rejected symlinks.
- Memory readers search private Git-ignored Markdown and normalize root paths
  before resolving accepted decision status and supersession.
- Each SessionStart delivers context, so later compactions restore memory even
  when the session and memory revision are unchanged.
- Regression fixtures cover ignored Git repositories, equivalent memory roots,
  repeated compactions, and rejected or partially completed restores.

## v0.2.0-alpha.1 (2026-10-12)

Control-plane correctness and runtime integration update.

- Portable shared secret detection/redaction now verifies replacement, and all
  memory readers sanitize source documents plus complete output.
- Effective accepted decision graphs govern constraints; proposals and deprecated
  records remain advisory. Invalid graphs report unavailable validation.
- Per-root kernel locks and exclusive atomic publication prevent concurrent
  index loss and immutable-record overwrites.
- Project actions/blockers use latest explicit snapshots and respect clearing.
- Compact policy and skill routers use detailed references and invocation metadata.
- Installer reconciles canonical/legacy skill discovery, five hook definitions,
  a source-root hook launcher, and three owned custom agent roles.
- Curated config reconciliation preserves app-owned settings and backs up changes.
- Private scanned snapshots restore Markdown memory and index together while
  preserving the transaction lock inode.
- Doctor adds metadata, reference, dependency, schema, index, and vendor checks;
  verification adds 65 behavioral tests, including 96 concurrent writes.
- The separately maintained local Playwright wrapper pins CLI 0.1.19 and passed
  an installed help smoke test; its bundle remains outside this change.

Compatibility: Python 3.11+, Bash 3.2+, macOS/Linux. Missing decision status is
advisory. Private memory remains Git-ignored. Hook trust must be reviewed through
Codex's normal review UI before definitions run; installation never grants trust.
Beta permission profiles and native memories remain optional.

Verification:

```bash
bin/verify.sh
```


## v0.1.0-alpha.1 (2026-03-04)

Initial alpha release of **Codex Context Agents**: a files-first, git-backed state layer for Codex with deterministic skill workflows, structured memory, and safety guards.

### Release Type

- `alpha` pre-release
- not production-stable
- intended for early adopters validating workflow and conventions

### Included In This Release

1. Core project policy and operator docs
- `AGENTS.md`: runtime behavior contract and operating constraints
- `README.md`: setup, workflows, command examples, and official Codex docs links
- `assets/codex-context-agents-logo.png`: repository branding asset

2. Install and health-check tooling
- `bin/install.sh`: symlink reconciliation and setup flow
- `bin/doctor.sh`: environment and configuration checks

3. Shared security utility
- `lib/secret_scan.sh`: central policy engine for secret detection/redaction/blocking

4. Memory system scaffold and conventions
- `memory/README.md`: memory operating conventions
- `memory/index.md`: durable memory anchors index
- `memory/{decisions,knowledge,logs,patterns,projects}/.gitkeep`: scaffold for shareable structure
- `.gitignore` policy keeps personal memory entries out of version control while preserving template structure

5. Skill system (deterministic workflow primitives)
- `context-bootstrap`
- `decision-check`
- `decision-record`
- `memory-index-update`
- `memory-retrieve`
- `memory-write`
- `project-status`
- `project-update`
- `runbook-create`
- `secret-scan`
- `workflow-plan`
- utility skills: `gh-address-comments`, `security-best-practices`

### Behavior and Safety Baseline

- Decision-first workflow before architecture/workflow changes (`decision-check`)
- Mandatory context bootstrap for non-trivial tasks (`context-bootstrap`)
- Append-only conventions for logs/project logs and immutable decisions
- Write-side secret enforcement with explicit redaction override (`--allow-redact`)
- Source-of-truth model via symlinks from `~/.codex/*` to this repository

### Semantic Versioning Policy (Alpha Phase)

This project follows **Semantic Versioning** with pre-release identifiers:

- Format: `MAJOR.MINOR.PATCH-alpha.N`
- Current: `0.1.0-alpha.1`
- During `0.x`, breaking changes may occur between minor releases
- `alpha.N` increments for iterative preview drops before first stable release

### Verification Steps

Run these checks before publishing the tag/release:

```bash
bin/verify.sh
```

Expected result:
- no syntax errors from `bash -n`
- scripts remain executable in your shell environment

### Known Limitations (Alpha)

- Workflow contracts may change while conventions are refined
- Memory content is intentionally local/private by default via `.gitignore`
- Cross-machine behavior depends on consistent symlink setup and shell tooling
