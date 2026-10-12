# Codex control plane review

Reviewed October 12, 2026.

Keep the repository as the authoritative layer for policy, decisions, project state, and reusable procedures. Its structure is useful, but its behavioral guarantees need repair before lifecycle automation increases the frequency of memory reads and writes. The first priorities are effective secret redaction, decision supersession, and safe concurrent writes.

## Context

No relevant decision found. Context bootstrap returned no relevant project or pattern evidence, and the memory index has no anchors. Recommendations below are proposals; they do not establish new accepted decisions.

## Observed setup

| Item | Observed state |
| --- | --- |
| Authoritative repository | `/Users/axios/.config/codex-agents` |
| Global policy and legacy skills links | Both point to this repository correctly |
| Documented user skill location | `/Users/axios/.agents/skills` is absent; legacy discovery works in this session |
| CLI | `codex-cli 0.159.2` |
| Desktop app | `26.928.31416`, build `12553`, production channel |
| App update check | Returned `busy`; eligible update status remains unresolved |
| CLI features | Hooks, plugins, multi-agent, worktrees enabled; native memories disabled |
| User hooks | No `~/.codex/hooks.json` or inline user hooks found |
| Runtime configuration | Regular `~/.codex/config.toml`, outside this repository; valid TOML |
| Model defaults | `gpt-6.1-sol`, reasoning effort `ultra` |
| Context7 | Configured, but its tools are unavailable in this session |
| Doctor | All 38 current structural checks pass |

The repository has existing uncommitted bundled skill changes and new skill directories. Their provenance needs review before accepting them as a release. The review does not establish whether any separately managed or plugin hooks are active elsewhere.

## Findings to fix first

### P1 Secret scanning can claim redaction without removing the value

[The shared scanner](/Users/axios/.config/codex-agents/lib/secret_scan.sh:54) detects some values case-insensitively, but its replacement expressions are case-sensitive. Its JWT and hex replacements also use a word-boundary expression that does not work with the tested macOS `sed`.

Isolated synthetic fixtures produced these results:

| Fixture | Scanner result | Original value retained |
| --- | --- | --- |
| Uppercase API_KEY assignment, normal write policy | `redacted`, exit 0 | Yes |
| Lowercase bearer value, explicit redaction override | `redacted`, exit 0 | Yes |
| JWT-shaped value, normal write policy | `redacted`, exit 0 | Yes |
| Long hex value, normal write policy | `redacted`, exit 0 | Yes |

The uppercase assignment was also persisted through `memory-write` while its report claimed redaction. Without the explicit override, the detected bearer case is blocked; the defect is in the permitted redaction path. No real credentials were used in these fixtures.

Use one portable implementation for detection and replacement, then verify that recognized values are absent from the final content. A standard-library Python scanner would make matching behavior consistent across macOS and Linux. Keep the existing pass/redact/block contract and explicit override policy.

### P1 Memory readers have incomplete and inconsistent filtering

[memory-retrieve](/Users/axios/.config/codex-agents/skills/memory-retrieve/scripts/retrieve.sh:156) has its own reduced redactor and prints [headings without sanitizing them](/Users/axios/.config/codex-agents/skills/memory-retrieve/scripts/retrieve.sh:1131). [decision-check](/Users/axios/.config/codex-agents/skills/decision-check/scripts/check.sh:104) has a separate token expression that misses project-prefixed API tokens.

Fixtures confirmed that API-token-shaped values can appear in retrieved bodies, headings, and decision constraints. Repair the shared scanner first, then use it for every model-visible field and the complete final output. Sanitize before excerpt truncation, and test titles, paths, status, constraints, and error messages as well as body text.

### P1 Superseded decisions remain enforceable

[decision-check](/Users/axios/.config/codex-agents/skills/decision-check/scripts/check.sh:474) collects constraints from every selected decision, including predecessors. It reports supersession metadata but does not remove the old constraints from the [final enforcement list](/Users/axios/.config/codex-agents/skills/decision-check/scripts/check.sh:494).

An accepted SQLite replacement superseding an accepted Redis decision caused both requirements to appear as constraints to obey, including through bootstrap. No conflict warning appeared when both decisions had the same status.

[Retrieval ranking](/Users/axios/.config/codex-agents/skills/memory-retrieve/scripts/retrieve.sh:722) also penalizes the replacement simply because it declares `Supersedes:`, alongside penalizing its predecessor.

Resolve supersession across the decision set before selecting results. Enforce effective accepted decisions; present proposed and deprecated records as context. A proposed replacement should not retire an accepted predecessor. Detect missing targets and cycles, and test multi-step replacement chains.

### P1 Parallel writes can lose index entries and overwrite decisions

[Index insertion](/Users/axios/.config/codex-agents/skills/memory-index-update/scripts/update_index.sh:214) reads, rewrites, and replaces the index without a lock. [Decision creation](/Users/axios/.config/codex-agents/skills/decision-record/scripts/record.sh:345) checks filename availability before opening it for an overwriting write.

In one isolated run, 20 simultaneous successful index updates retained only 7 links. Another run produced only 19 files from 20 successful same-title decision writes. These counts are observations from race reproductions, not fixed failure rates.

Serialize each mutation transaction, use exclusive file creation for immutable records, and create replacement files on the destination filesystem before atomic rename. Preserve complete project-log entries as one operation. Choose a portable lock implementation with timeout and stale-lock handling; do not assume `flock` exists on macOS. Let one agent own memory mutations until these guarantees are tested.

### P2 Project status can reintroduce completed work and cleared blockers

[Task parsing](/Users/axios/.config/codex-agents/skills/project-status/scripts/status.sh:123) removes checked and unchecked markers alike. [Aggregation](/Users/axios/.config/codex-agents/skills/project-status/scripts/status.sh:397) combines several updates without respecting explicit clearing.

A checked task appeared under Next Actions; an older blocker reappeared after the latest entry declared no blockers. Define whether log fields are snapshots or deltas. For snapshots, take the latest explicit field, preserve an explicit empty value, and exclude completed tasks from current actions.

### P2 Bootstrap failure can look like an empty decision search

[Bootstrap's empty-constraint branch](/Users/axios/.config/codex-agents/skills/context-bootstrap/scripts/bootstrap.sh:513) prints the same no-decision conclusion after a source failure. A missing decisions directory produced that conclusion alongside a sanitized failure note, while bootstrap exited successfully.

Keep the non-aborting behavior, but distinguish successful empty retrieval from unavailable decision validation. A hook should propagate that distinction so the agent can repair retrieval before relying on an architectural conclusion.

## Setup and skill improvements

1. **Update discovery and installation checks.** [Installer](/Users/axios/.config/codex-agents/bin/install.sh:200) and [doctor](/Users/axios/.config/codex-agents/bin/doctor.sh:196) only manage the legacy skills location. Add the documented `~/.agents/skills` path, verify duplicate handling, retain compatibility until each client is checked, and respect `CODEX_HOME` for global instructions. Current docs support symlinked skill folders. [Build skills](https://learn.chatgpt.com/docs/build-skills), [AGENTS discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md).

2. **Make bootstrap the single read router.** [AGENTS.md](/Users/axios/.config/codex-agents/AGENTS.md:37) repeats retrieval obligations in several places. This same policy file is also used globally and at the repository root. Keep compact invariants in global guidance and move mechanics into skill references. Global and project instruction sources are concatenated. [AGENTS discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md).

3. **Improve invocation metadata without removing useful scripts.** The eleven custom memory skills lack `agents/openai.yaml`. Keep bootstrap readily discoverable; consider explicit-only selection for subordinate write workflows and retain their scripts as reusable primitives. Current metadata supports invocation policy and MCP dependencies. The initial skill catalog has a context budget and can omit skills, so front-load concise descriptions. [Build skills](https://learn.chatgpt.com/docs/build-skills).

4. **Clarify configuration ownership.** Keep authored configuration, hook definitions, rules, agent profiles, and a desired-state manifest here. Reconcile curated values with desktop-managed configuration instead of copying the entire active config. Give bundled `.system` skills an explicit upstream version and update procedure, separate from personal policy. The current `js_repl = false` entry refers to a removed feature according to this CLI; review stale keys during reconciliation.

5. **Provide actual private-memory recovery.** [.gitignore](/Users/axios/.config/codex-agents/.gitignore:16) intentionally excludes personal memory. A repository path does not provide Git rollback for ignored files. Document a private backup or snapshot mechanism, and test restoring entries and their index together. Keep the public scaffold shareable.

6. **Expand doctor and repair published verification.** Add metadata, referenced-file, dependency, discovery, index-target, and behavioral checks. [README](/Users/axios/.config/codex-agents/README.md:194) and [release notes](/Users/axios/.config/codex-agents/RELEASE_NOTES.md:69) show `bash -n` with multiple filenames; that parses only the first script. Doctor already uses the correct per-file loop.

7. **Make specialist workflows capability-aware.** Add official-documentation fallback when Context7 is unavailable. Make the [PR comment skill](/Users/axios/.config/codex-agents/skills/gh-address-comments/SKILL.md:17) ask for scope only when it is ambiguous, and request elevated execution only when needed. Pin the [Playwright CLI wrapper](/Users/axios/.config/codex-agents/skills/playwright/scripts/playwright_cli.sh:19) to a tested release if you maintain that dependency here.

## Hooks adoption proposal

The updated documentation supports command and MCP handlers. Hook sources accumulate, matching commands may run concurrently, and changed non-managed definitions need renewed trust. Synchronous hooks can control supported operations; asynchronous hooks only provide later feedback. Tool coverage is incomplete. Scanner exit 3 needs translation into supported denial output. `Stop` requires JSON and can create continuation turns; guard with `stop_hook_active`. Local command hooks do not carry over to cloud orchestration. Keep output bounded and sanitized. [Hooks](https://learn.chatgpt.com/docs/hooks).

Proposed integration:

| Event | Control-plane job |
| --- | --- |
| SessionStart | Show a compact health/ownership summary; on compact, restore authoritative constraint pointers |
| UserPromptSubmit | Run task-derived bootstrap once, with explicit project mapping and bounded retrieval |
| SubagentStart | Inject a short ownership contract and relevant constraint pointers |
| PreToolUse | Apply narrowly defined memory-mutation guardrails through a JSON adapter |
| PostToolUse | Collect advisory health feedback after relevant mutations |
| Stop | Check a concrete task-completion record, with a bounded retry policy |

Store hook source and adapters here, expose them through reviewed installation, and begin with read-only context injection. Review definitions through `/hooks`. Do not attach raw scanner or doctor output directly to a blocking event. Keep validation and persistence together inside one controlled writer rather than separate sibling hooks. Use per-event deduplication, transaction locks, explicit timeouts, and a small output budget.

Retain the current memory-write eligibility policy. Selective, validated decision/project updates provide more useful continuity than automatically copying whole transcripts into durable memory.

## Current Codex features worth adopting

| Feature | Application to this setup |
| --- | --- |
| Hooks GA, May 14, 2026 | Move mandatory bootstrap execution into a tested adapter after the P1 repairs. [Changelog](https://learn.chatgpt.com/docs/changelog) |
| Updated instruction guidance, September 11 | Shorter triggers, a small router, and contextual retrieval fit this system well. [OpenAI guidance](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra) |
| GPT-6.1 Sol, September 29; Ultrafast, October 8 | Your configured model is already current. Ultrafast is an optional latency improvement on eligible plans, not a control-plane prerequisite. [Changelog](https://learn.chatgpt.com/docs/changelog) |
| Native custom agents | Version narrow retriever, documentation, and reviewer roles here; expose personal TOML roles through `~/.codex/agents`. Parent live permission overrides can supersede role defaults. [Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents) |
| Permission profiles, beta | Consider separate inspection and memory-edit policies after validating client behavior. Legacy sandbox settings can override profiles; domain filtering needs an active network proxy. [Permissions](https://learn.chatgpt.com/docs/permissions) |
| Native local memories | Optional recall around your authoritative records. The generated `~/.codex/memories` store is separate and should not replace or be symlinked onto your structured memory. [Memories](https://learn.chatgpt.com/docs/customization/memories) |
| Portable plugins | Useful for sharing reusable skills and scripts after stabilization. Use the current root manifest format; exclude private memory. Cached installs require refresh verification. [Package your plugin](https://developers.openai.com/plugins/build/plugins) |

Published feature documentation does not establish account access or exact desktop availability. The local CLI feature listing establishes only the observed CLI state. The app update check did not determine whether an eligible update exists.

## Proposed implementation order and acceptance

1. **Repair memory correctness.** Unify and verify redaction; resolve effective decisions; serialize mutations; respect completed tasks and cleared blockers. Accept only when synthetic secret fixtures never reach output/storage, superseded rules disappear, and concurrent writes retain every successful transaction.
2. **Improve ownership and verification.** Update discovery, reduce repeated policy, add metadata, make dependency fallbacks explicit, document private backup, and pin vendor provenance. Verify CLI and desktop skill discovery separately and perform a private restore drill.
3. **Pilot read-only hooks.** Add an event adapter and lifecycle fixtures. Verify startup, resume, task submission, compaction, subagent startup, changed-definition trust, source duplication, and malformed input. Confirm existing bootstrap obligations still execute when hooks are unavailable.
4. **Introduce narrowly scoped guardrails.** Test supported denial paths and bounded completion continuation before enabling them globally. Keep observability to event IDs, revision, duration, status, and sanitized diagnostics.

Each stage should have its own reviewable commit. Roll back hook behavior by disabling the new handlers or restoring the prior definition; restore authored files from the reviewed commit and private memory from its tested snapshot. Keep enforcement inside writers even when hooks are disabled.

## Verification commands

Run structural checks:

```bash
cd /Users/axios/.config/codex-agents
bin/doctor.sh
skills/context-bootstrap/scripts/bootstrap.sh 'codex control plane skills hooks' --max-items 7
codex --version
codex features list
```

Expected current results: doctor passes, bootstrap reports no relevant decision, CLI reports 0.159.2, and hooks are enabled. These checks do not establish behavioral safety.

Parse every shell script independently:

```bash
cd /Users/axios/.config/codex-agents
while IFS= read -r script; do
  bash -n "$script" || exit 1
done < <(rg --files --hidden -g '*.sh' -g '!.git/**' bin lib skills)
```

Replay the isolated diagnostic probes:

```bash
python3 /Users/axios/.config/codex-agents/reviews/control-plane-probe.py
```

The probe creates disposable memory roots in the system temporary directory and prints presence booleans and counts, without displaying synthetic token values. It leaves those temporary fixtures for inspection. Its process exit status reports execution, not a passing regression suite: the current defects appear as retained values, contradictory constraints, lost transactions, and stale actions. Concurrency counts vary between runs.

Turn these probes into regression assertions during the repair stage. Expand coverage to scanner case/boundary variants, all reader fields, supersession chains/statuses, concurrent index and decision writes, completion/clear semantics, and unavailable-source handling. Add hook lifecycle fixtures in the hook-adoption stage.


## Implementation update October 12 2026

The P1 repairs and setup changes are implemented. All 65 behavioral regressions
pass, including 96 concurrent writes; the live doctor reports 121 passes and two
advisory warnings. Codex's
app-server discovers each owned skill once with zero errors and loads all five
hook definitions without warnings. Their trust state is initially untrusted;
activation requires the normal Hooks review flow. Computer Use cannot operate
Codex's own review screen.

The [operator guide](/Users/axios/.config/codex-agents/README.md) describes current
installation, invocation, recovery, and limitations. The [verification entrypoint](/Users/axios/.config/codex-agents/bin/verify.sh)
runs the suite. Private source decisions and project continuity are recorded
through the repaired writers. A pre-upgrade memory snapshot and original runtime
config backup are stored inside ignored `.private/`.

Optional beta permissions, native recall, Ultrafast, and plugin distribution were
left as explicit choices; the installed source-of-truth architecture does not
require them.

## Activation verification October 12 2026

The user reviewed and trusted all five definitions. Live discovery now reports
them enabled and trusted without loading errors or warnings. SessionStart,
UserPromptSubmit, SubagentStart, and the PreToolUse memory-edit guard were
observed in this chat. The [activation report](2026-10-12-hook-activation-verification.json)
records those checks.

A genuine ephemeral Codex session also verified Stop: a deliberately failed
check requested one continuation, then the second Stop allowed completion while
the same turn's receipt remained failed. The [live Stop report](2026-10-12-stop-live-verification.json)
records both native hook notifications and completion. Raw `stop_hook_active`
input is not exposed; its guard is verified through the controlled behavior.
Test receipts were removed after completion. Hook definitions and trust were
unchanged.
