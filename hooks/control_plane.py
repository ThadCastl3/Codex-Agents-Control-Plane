#!/usr/bin/env python3
"""Local lifecycle adapter: bounded context, direct-edit guard, recorded checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "lib"))
from memory_transaction import memory_lock, publish_file
from secret_scan import scan_text

MAX_INPUT = 2 * 1024 * 1024
MAX_CONTEXT_BYTES = 4800


def safe(text):
    return scan_text(text, mode="read")["redacted_text"]


def identity(*items):
    return hashlib.sha256(json.dumps(items, ensure_ascii=True).encode()).hexdigest()


def revision(memory):
    files = sorted(memory.rglob("*.md")) if memory.is_dir() else []
    stats = []
    for path in files[:10000]:
        if path.is_symlink():
            continue
        stat = path.stat()
        stats.append((str(path.relative_to(memory)), stat.st_size, stat.st_mtime_ns))
    return identity(stats)


def project_for(cwd, memory):
    mapping = json.loads((REPO / "config" / "project-map.json").read_text())
    matches = []
    for item in mapping:
        root = Path(os.path.expandvars(item["root"])).expanduser().resolve()
        if cwd.is_relative_to(root) and (memory / "projects" / item["project"]).is_dir():
            matches.append((len(root.parts), item["project"]))
    return max(matches)[1] if matches else None


def query_for(prompt):
    words = re.findall(r"[a-zA-Z0-9][a-zA-Z0-9_-]{2,}", safe(prompt))
    ignored = {"the", "and", "please", "you", "can", "with", "that", "this", "for", "from", "into", "could", "would", "redacted"}
    selected = list(dict.fromkeys(word.lower() for word in words if word.lower() not in ignored))[:16]
    return " ".join(selected)[:300] or "project status decisions"


def bootstrap(query, project, memory):
    command = [str(REPO / "skills" / "context-bootstrap" / "scripts" / "bootstrap.sh"), query, "--max-items", "5", "--max-updates", "3"]
    if project:
        command.extend(["--project", project])
    env = dict(os.environ, MEMORY_ROOT=str(memory))
    result = subprocess.run(command, cwd=REPO, env=env, capture_output=True, text=True, timeout=12)
    if result.returncode:
        return "Context bootstrap unavailable; run the entrypoint manually before recommendations.", False
    output = safe(result.stdout).strip()
    complete = len(output.encode()) <= MAX_CONTEXT_BYTES - 500
    if not complete:
        output = output.encode()[:MAX_CONTEXT_BYTES - 700].decode(errors="ignore") + "\nContext shortened; run task-specific bootstrap manually before relying on this summary."
    available = not re.search(r"decision (?:validation|context) unavailable|skill=[^\s]+ exit_code=\d+ failed", output.lower())
    return output, complete and available


def guard_patch(event, memory):
    tool = event.get("tool_input", {})
    if not isinstance(tool, dict) or not isinstance(tool.get("command"), str):
        return {}
    cwd = Path(event.get("cwd", str(REPO))).resolve()
    roots = (memory, Path(os.path.abspath(os.path.expanduser(os.environ.get("MEMORY_ROOT", str(REPO / "memory"))))))
    patches = re.findall(r"^\*\*\* (?:Add|Update|Delete) File: (.+)$|^\*\*\* Move to: (.+)$", tool["command"], re.MULTILINE)
    for first, second in patches:
        candidate = Path((first or second).strip()).expanduser()
        candidate = Path(os.path.abspath(candidate if candidate.is_absolute() else cwd / candidate))
        for checked in (candidate, candidate.parent.resolve() / candidate.name, candidate.resolve()):
            for root in roots:
                if not checked.is_relative_to(root):
                    continue
                relative = checked.relative_to(root)
                if relative == Path("index.md") or (relative.parts and relative.parts[0] in {"decisions", "projects", "knowledge", "patterns", "logs"} and checked.suffix == ".md"):
                    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Use the control-plane memory writer for this mutation so scanning, schema validation, and transaction locking run together."}}
    return {}


def receipt_path(state, session, turn):
    return state / "checks" / (identity(session, turn) + ".json")


def record_check(session, turn, command, memory, state):
    if not command:
        raise ValueError("a verification command is required")
    result = subprocess.run(command, cwd=REPO, capture_output=True, text=True, timeout=300)
    if result.stdout:
        print(safe(result.stdout), end="")
    if result.stderr:
        print(safe(result.stderr), end="", file=sys.stderr)
    record = {"status": "passed" if result.returncode == 0 else "failed", "revision": revision(memory)}
    with memory_lock(state):
        receipt = receipt_path(state, session, turn)
        receipt.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        publish_file(receipt, json.dumps(record).encode(), replace=True)
    return result.returncode


def delivery_key(event, memory):
    return identity(event.get("hook_event_name"), event.get("session_id"), event.get("turn_id"), event.get("source"), event.get("agent_id"), identity(event.get("prompt", "")), revision(memory))


def handle(event, memory, state):
    # SessionStart carries no per-occurrence turn ID. A later resume or compact
    # can have the same payload and memory revision, but needs fresh context.
    if event.get("hook_event_name") not in {"UserPromptSubmit", "SubagentStart"}:
        return handle_event(event, memory, state)
    key = delivery_key(event, memory)
    # Bounded lock buckets serialize duplicate invocations before retrieval.
    with memory_lock(state / "events" / key[:2], timeout=15):
        with memory_lock(state, timeout=3):
            file = state / "delivered.json"
            delivered = json.loads(file.read_text()) if file.exists() else []
            if not isinstance(delivered, list) or not all(isinstance(item, str) for item in delivered):
                raise ValueError("invalid delivery record")
            if key in delivered:
                return {}
        return handle_event(event, memory, state, key)


def handle_event(event, memory, state, key=None):
    name = event.get("hook_event_name")
    if name == "PreToolUse":
        return guard_patch(event, memory) if event.get("tool_name") == "apply_patch" else {}
    if name == "Stop":
        if event.get("stop_hook_active"):
            return {}
        session, turn = event.get("session_id"), event.get("turn_id")
        if not session or not turn:
            return {}
        receipt = receipt_path(state, session, turn)
        if receipt.is_file():
            record = json.loads(receipt.read_text())
            if not isinstance(record, dict) or record.get("status") not in {"passed", "failed"}:
                raise ValueError("invalid verification receipt")
            if record.get("status") == "failed":
                return {"decision": "block", "reason": "The recorded control-plane verification failed. Run bin/verify.sh and resolve its failures before completing this turn."}
        return {}
    if name not in {"SessionStart", "UserPromptSubmit", "SubagentStart"}:
        return {}
    cwd = Path(event.get("cwd", str(REPO))).resolve()
    project = project_for(cwd, memory)
    if name == "SubagentStart":
        context = "Respect the parent's effective constraints. Return concise evidence. Use scanned control-plane writers for eligible memory changes; coordinate ownership before writing."
    elif name == "SessionStart":
        context = f"Authored control plane: {REPO}. Structured memory is authoritative. Native generated memories are optional recall."
        if event.get("source") == "compact":
            restored, complete = bootstrap((project or "") + " decisions policy constraints next", project, memory)
            context += "\n" + restored
            if complete:
                context += "\nBootstrap completed for compaction restoration; perform task-specific retrieval when the task changes."
    else:
        prompt = event.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            return {}
        context, complete = bootstrap(query_for(prompt), project, memory)
        context += "\n" + ("Bootstrap completed for this task." if complete else "Bootstrap requires a manual follow-up before recommendations.")
    context = safe(context)
    if len(context.encode()) > MAX_CONTEXT_BYTES:
        context = context.encode()[:MAX_CONTEXT_BYTES - 250].decode(errors="ignore")
        context = context.replace("Bootstrap completed for this task.", "")
        context += "\nContext shortened; run task-specific bootstrap manually before recommendations."
    if key is not None:
        # Only bookkeeping is persisted, never raw prompts or transcripts.
        with memory_lock(state, timeout=3):
            file = state / "delivered.json"
            delivered = json.loads(file.read_text()) if file.exists() else []
            if not isinstance(delivered, list) or not all(isinstance(item, str) for item in delivered):
                raise ValueError("invalid delivery record")
            if key in delivered:
                return {}
            publish_file(file, json.dumps((delivered + [key])[-256:]).encode(), replace=True)
    return {"hookSpecificOutput": {"hookEventName": name, "additionalContext": context}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record-check", action="store_true")
    parser.add_argument("--session-id")
    parser.add_argument("--turn-id")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    memory = Path(os.environ.get("MEMORY_ROOT", str(REPO / "memory"))).expanduser().resolve()
    state = Path(os.environ.get("CODEX_CONTROL_PLANE_RUNTIME", str(REPO / ".private" / "runtime"))).expanduser().resolve()
    if args.record_check:
        if not args.session_id or not args.turn_id:
            parser.error("record-check requires session-id and turn-id")
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        try:
            return record_check(args.session_id, args.turn_id, command, memory, state)
        except (ValueError, OSError, subprocess.TimeoutExpired, TimeoutError):
            print("Verification could not execute; no successful check was recorded.", file=sys.stderr)
            return 2
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            raise ValueError("oversized event")
        event = json.loads(raw)
        if not isinstance(event, dict):
            raise ValueError("event must be an object")
        for field in ("cwd", "session_id", "turn_id", "hook_event_name", "source", "agent_id", "agent_type"):
            if field in event and event[field] is not None and not isinstance(event[field], str):
                raise ValueError("invalid event field type")
        output = handle(event, memory, state)
    except (ValueError, TypeError, OSError, subprocess.TimeoutExpired, TimeoutError):
        # Hook errors are advisory; a specific supported denial is required to block.
        output = {"systemMessage": "Control-plane hook unavailable or invalid input; run context bootstrap manually before recommendations."}
    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
