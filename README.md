<p align="center">
  <img src="assets/codex-context-agents-logo.png" alt="Codex Context Agents logo" width="220" />
</p>

# Codex Context Agents

A files-first control plane for Codex. Authored policy, skills, configuration,
and structured memory live in `~/.config/codex-agents`.

Code and policy are versioned. Private memory entries are Git-ignored and have
an explicit local snapshot/restore path. Codex-generated native memories remain
an optional recall layer around the authoritative records here.

## Runtime

Requires macOS or Linux, Bash 3.2+, and Python 3.11+. The core uses the Python
standard library; `rg` is preferred, with a slower search fallback. The optional
The separately maintained local Playwright workflow requires Node/npm. Its
wrapper pins `@playwright/cli@0.1.19`; that bundled skill is outside the authored
control-plane changes.

## Install and verify

```bash
cd ~/.config/codex-agents
bin/install.sh --dry-run
bin/install.sh
bin/verify.sh
```

The installer reconciles these owned symlinks:

| Entrypoint | Repository source |
| --- | --- |
| `${CODEX_HOME:-~/.codex}/AGENTS.md` | `AGENTS.md` |
| `${CODEX_HOME:-~/.codex}/skills` | `skills/` (legacy compatibility) |
| `~/.agents/skills` | `skills/` (documented discovery) |
| `${CODEX_HOME:-~/.codex}/hooks.json` | `config/hooks.json` |
| `${CODEX_HOME:-~/.codex}/control-plane-hook.py` | `hooks/control_plane.py` |
| Three owned `${CODEX_HOME:-~/.codex}/agents/*.toml` files | `config/agents/*.toml` |

Use `--codex-home` and `--agents-home` for isolated installation fixtures.
An existing foreign hooks file is preserved: reconcile its hooks explicitly
before installation. Unrelated custom agent files stay in place.

`config/desired-state.json` owns only a small set of runtime feature values.
Installation enables the hooks feature and removes the retired `js_repl` key,
while preserving all other TOML values and comments. It backs up changed paths
inside ignored `.private/install-backups/`. Symlinked config backups retain
original contents. Installation does not replace the whole desktop config or
change your chosen model, reasoning effort, MCP credentials, or permissions.

Review the installed definitions in Codex's Hooks settings or `/hooks` before
trusting them. Installation never grants trust or uses a trust-bypass flag.
Restart/resume a client when needed to refresh configuration and discovery.

## Policy and skill routing

`AGENTS.md` is the compact global policy. `AGENTS.override.md` supplies only
repository-maintenance guidance, avoiding duplicate loading of the global
policy when working in this repository.

`context-bootstrap` is the implicit read router. The ten subordinate memory
skills remain available through explicit invocation and their deterministic
scripts. Each has a small `SKILL.md`, invocation metadata, and a detailed
`references/contract.md`. Read the applicable contract before a write.

```bash
skills/context-bootstrap/scripts/bootstrap.sh 'control plane hooks memory' \
  --project codex-agents --max-items 5
```

A complete hook-provided bootstrap for the same task satisfies the read gate.
Unavailable checks require manual follow-up; they never mean no decision exists.

| Workflow | Entrypoint |
| --- | --- |
| Context routing | `skills/context-bootstrap/scripts/bootstrap.sh` |
| Effective accepted decisions | `skills/decision-check/scripts/check.sh` |
| Bounded retrieval | `skills/memory-retrieve/scripts/retrieve.sh` |
| Current project snapshots | `skills/project-status/scripts/status.sh` |
| Immutable decision creation | `skills/decision-record/scripts/record.sh` |
| Project log append | `skills/project-update/scripts/update.sh` |
| Knowledge / chronological capture | `skills/memory-write/scripts/write.sh` |
| New anchor registration | `skills/memory-index-update/scripts/update_index.sh` |
| Tracked execution plans | `skills/workflow-plan/scripts/plan.sh` |
| Reusable procedures | `skills/runbook-create/scripts/create.sh` |
| Shared scanning | `skills/secret-scan/scripts/scan.sh` |

Specialist PR-comment and Playwright skills remain available. PR work follows
existing authorization; it asks for scope only when scope is ambiguous.
Context7 is preferred when callable, with a primary-documentation fallback.

## Memory guarantees

Write only for explicit storage requests, durable decisions, reusable procedures,
or material project-state changes. All writers share portable scanning and a
per-memory-root kernel lock; nested index/project writes inherit a validated
lock descriptor. The persistent `.memory-transaction.lock` must never be deleted
or replaced while writers can run. Kernel locks release after their owners exit.

High-confidence findings block writes unless `--allow-redact` is explicit.
Low-confidence findings are redacted. Detection and replacement use the same
rules, with a verification scan after redaction. Readers sanitize whole source
documents before excerpts and sanitize complete stdout/stderr before release.
Missing scanner dependencies withhold output and stop writes.

Memory searches include private Git-ignored Markdown documents. Reader roots
are normalized so absolute paths, relative paths, and trailing slashes preserve
the same decision authority and evidence paths.

Only effective records explicitly marked `Status: accepted` are binding.
Accepted replacements retire their predecessors; proposed replacements do not.
Missing/ambiguous targets, cycles, and competing accepted replacement branches
return exit 3. Other invalid inputs or unavailable dependencies return exit 2.
Linked decision sources are rejected before graph resolution. Bootstrap stays
non-aborting and labels unavailable decision context.

Project `Next` and `Blockers` fields are independent snapshots. The latest
explicit field wins; `None` or an empty field clears it. Checked tasks are
excluded from current actions. Missing fields inherit an earlier explicit value.
The `--since` filter affects recent history, not current state.

Locks prevent concurrent corruption; they do not roll back every failed
multi-file operation. Immutable files are published exclusively and index
replacements are atomic. Use snapshots for recovery from partial operations.

## Hooks

The authored hooks are local command handlers:

- `SessionStart`: ownership summary and context restoration after compaction.
- `UserPromptSubmit`: bounded task-derived bootstrap, with `config/project-map.json`.
- `SubagentStart`: concise constraint and write-ownership instructions.
- `PreToolUse`: reject direct `apply_patch` mutations to structured memory so writers
  perform scanning, schema handling, and locking together.
- `Stop`: one bounded continuation if a verification receipt for this turn failed.

The direct-edit guard is defense in depth; it does not inspect every shell or
hosted-tool write. Writer enforcement remains active when hooks are unavailable.
The adapter caps context at 4,800 UTF-8 bytes, sanitizes it, and deduplicates
matching prompt and subagent events before retrieval. Every `SessionStart`
delivers context, including each compaction with unchanged memory.
`additionalContextLimit = 0` avoids a second
approximate token-based spill after that strict byte cap. Bookkeeping contains
hashes/status only and never stores raw prompts or transcripts.

A Stop hook does nothing without an explicit verification receipt. Record an
actual check when session and turn IDs are known:

```bash
python3 hooks/control_plane.py --record-check \
  --session-id '<session-id>' --turn-id '<turn-id>' -- bin/verify.sh
```

The wrapper records the command's actual result and sanitizes its output.
A continuation already marked `stop_hook_active` is never repeated.
Local command hooks are not a portable policy boundary for cloud orchestration.
See [official hooks documentation](https://learn.chatgpt.com/docs/hooks).

## Private memory recovery

```bash
bin/memory-snapshot.py create
bin/memory-snapshot.py list
bin/memory-snapshot.py restore '<snapshot-name>'
```

Snapshots include visible Markdown documents and the index together. They
exclude lock/runtime files, reject symlinks and unsafe paths, scan contents,
verify checksums, and live in mode-700 `.private/snapshots/`. A restore preserves
the live root and lock inode, captures a pre-restore snapshot, and restores
Markdown documents under the writer lock. Hidden and non-Markdown files are
outside this snapshot contract. Restore validates destination paths before
mutation and rolls back only its recorded changes after a failure.
Low-confidence content may be redacted; a
high-confidence finding requires an explicit sanitized-copy override.

These are local recovery copies, not encrypted disaster recovery. Copy them to
separately protected storage for machine-loss protection. Never publish private
memory or backups with a plugin or public repository.

## Validation and upstream updates

`bin/doctor.sh` checks structural health plus skill metadata/references, canonical
links, config/agent schemas, index targets, dependencies, and vendor checksums.
It distinguishes static Context7 configuration from live connectivity and does
not claim hook trust. `bin/verify.sh` adds behavioral regression tests in disposable
memory roots, syntax validation, and diff checks. Use `--skip-doctor` only while
preparing installation in an isolated checkout.

`config/vendor-manifest.json` records the exact installed `.system` snapshot.
The upstream revision is unknown; the manifest does not invent one. When Codex
updates bundled files, doctor reports drift without resetting them. Review
upstream changes separately from authored policy, smoke-test them, then capture
a new manifest intentionally. Existing bundled-skill diffs remain preserved.

Custom role TOMLs are authored here. Their read-only defaults can be superseded
by parent runtime permission overrides. `config/permissions.example.toml` is a
beta migration example, not installed automatically; remove legacy sandbox
settings before selecting profiles. Native memory, Ultrafast, plugin distribution,
and beta permission migration remain explicit optional choices.

Current behavior and limitations: [skills](https://learn.chatgpt.com/docs/build-skills),
[subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents),
[permissions](https://learn.chatgpt.com/docs/permissions),
[native memories](https://learn.chatgpt.com/docs/customization/memories).
