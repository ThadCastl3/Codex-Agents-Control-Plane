# Codex agent policy

`~/.config/codex-agents` is the source of truth for authored agent policy,
skills, configuration, and structured memory. Keep durable changes here.
Codex-facing policy, skills, hooks, and owned agent files are installed as
symlinks. Preserve unrelated desktop-managed configuration and bundled updates.

## Context before ongoing work

For non-trivial work tied to this system, run:

```bash
~/.config/codex-agents/skills/context-bootstrap/scripts/bootstrap.sh "<task-derived query>"
```

Read `memory/index.md` first. Bootstrap is the single read router: it runs
decision-check, project-status when a project is identified, and targeted
memory retrieval. Summarize applicable constraints, project status, patterns,
and evidence in a short `Context` section before recommendations.

Skip retrieval for stateless conceptual explanations, trivial rewriting, and
standalone examples. Use an explicit project hint when inference is ambiguous.
Hook-provided bootstrap for the current task satisfies this requirement when
its output is complete; otherwise run the script. Never treat unavailable
decision validation as a successful empty search.

Effective accepted decisions are binding. Superseded decisions are historical;
proposed and deprecated decisions are advisory. Resolve invalid supersession
graphs before architectural recommendations. If no decisions apply, state
`No relevant decision found.` Record each new durable constraint through
`skills/decision-record/scripts/record.sh`; never rewrite an old decision.

## Durable memory

Memory lives under `memory/{decisions,projects,knowledge,patterns,logs}`.
Write only when the user requests storage, a durable decision is made, a
reusable procedure emerges, or project state materially changes next actions.
Do not persist transient status, unrequested speculation, or credentials.

Read the relevant skill before a mutation and use its writer:

- Decisions: `decision-record`; one immutable file per decision.
- Project state: `project-update`; append complete log entries. `Next` and
  `Blockers` are snapshots; an explicit empty value clears previous state.
- Knowledge and chronological captures: `memory-write`.
- Reusable procedures: `runbook-create`; tracked execution plans: `workflow-plan`.
- New project, pattern, or knowledge anchors: `memory-index-update`.
  Writers register these automatically; never index logs.

All writers use the shared scanner and transaction lock. High-confidence
secrets block writes; low-confidence findings are redacted. `--allow-redact`
is an explicit per-command override that still removes the value. Read-side
scanning redacts without blocking retrieval. Never print keys or tokens.
Parallel agents may read independently; assign one owner for related writes.

Private entries are Git-ignored. Use `bin/memory-snapshot.py` for local recovery
and a separately protected copy for machine-loss recovery. Snapshots and
runtime bookkeeping stay in ignored `.private/` inside this repository.

## Evidence and completion

Prefer verified facts and small, reversible changes. For API or library
behavior, use Context7 when its tools are available; otherwise use official
documentation and disclose unresolved behavior. Use official OpenAI
documentation for Codex settings and supported feature behavior.

Preserve prior user authorization. Ask only for missing information that
materially changes scope, or an action that still requires approval. A skill
must not request repeated consent for already-authorized work.

Deliver concrete artifacts and appropriate verification. Call out material
impact, recovery, and remaining limitations. For control-plane changes run
`bin/verify.sh`; use disposable `MEMORY_ROOT` fixtures for behavioral tests.
Do not install or trust changed hooks by bypassing Codex's review flow.
