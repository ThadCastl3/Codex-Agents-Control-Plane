#!/usr/bin/env python3
"""Read-only structured validation of the authored Codex control plane.

Only the small YAML schema used by owned skills is supported, without PyYAML.
Unknown desktop-managed TOML values are left alone and never printed. Checks
report locations and fixed diagnostics, never configuration or memory content.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlsplit

try:
    import tomllib
except ImportError:
    tomllib = None

from secret_scan import scan_text

OWNED_SKILLS = {
    "context-bootstrap": "bootstrap.sh",
    "decision-check": "check.sh",
    "decision-record": "record.sh",
    "memory-index-update": "update_index.sh",
    "memory-retrieve": "retrieve.sh",
    "memory-write": "write.sh",
    "project-status": "status.sh",
    "project-update": "update.sh",
    "runbook-create": "create.sh",
    "secret-scan": "scan.sh",
    "workflow-plan": "plan.sh",
}
OWNED_AGENTS = {
    "memory-retriever.toml": "memory_retriever",
    "control-plane-reviewer.toml": "control_plane_reviewer",
    "docs-researcher.toml": "docs_researcher",
}
_KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$")
_INLINE_LINK = re.compile(r"!?\[[^\]\n]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+[\"'][^\n]*[\"'])?\s*\)")
_REFERENCE = re.compile(r"^\s{0,3}\[[^\]\n]+\]:\s*(<[^>]+>|\S+)", re.MULTILINE)


def scalar(value):
    """Parse authored YAML scalars; reject collections, aliases, and tags."""
    value = value.strip()
    if value.startswith('"'):
        return json.loads(value)
    if value.startswith("'"):
        if not value.endswith("'"):
            raise ValueError("unterminated quoted scalar")
        return value[1:-1].replace("''", "'")
    value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
    if value in ("true", "false"):
        return value == "true"
    if value in ("null", "~", ""):
        return None
    if re.fullmatch(r"[-+]?\d+(?:\.\d+)?", value):
        return float(value)
    if value.startswith(("[", "{", "*", "&", "!")):
        raise ValueError("unsupported authored YAML scalar")
    return value


def yaml_mapping(text):
    """Parse scalar mappings/block strings from owned YAML, or JSON-form YAML.

    Sequence bodies (optional tool dependencies) are not interpreted here. This
    is a deliberately small authoring validator, not a general YAML loader.
    """
    if text.lstrip().startswith("{"):
        result = json.loads(text)
        if not isinstance(result, dict):
            raise ValueError("mapping required")
        return result
    lines = text.splitlines()
    result = {}
    stack = [(-1, result)]
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "\t" in line[:len(line) - len(line.lstrip())]:
            raise ValueError("tabs in authored YAML indentation")
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if stripped.startswith("- "):
            # Dependencies are optional; do not confuse list-item fields with
            # required interface/policy scalar mappings.
            while i < len(lines):
                child = lines[i]
                child_indent = len(child) - len(child.lstrip())
                if child.strip() and child_indent < indent:
                    break
                i += 1
            continue
        match = _KEY.fullmatch(stripped)
        if not match:
            raise ValueError("invalid authored YAML mapping")
        key, raw = match.groups()
        while indent <= stack[-1][0]:
            stack.pop()
        mapping = stack[-1][1]
        if key in mapping:
            raise ValueError("duplicate authored YAML key")
        if re.fullmatch(r"[>|][+-]?", raw):
            body = []
            while i < len(lines):
                child = lines[i]
                child_indent = len(child) - len(child.lstrip())
                if child.strip() and child_indent <= indent:
                    break
                body.append(child.strip())
                i += 1
            mapping[key] = (" " if raw.startswith(">") else "\n").join(body).strip()
        elif not raw:
            nested = {}
            mapping[key] = nested
            stack.append((indent, nested))
        else:
            mapping[key] = scalar(raw)
    return result


def markdown_targets(text):
    """Return actual Markdown links, excluding fenced examples and inline code."""
    visible = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if marker:
            kind = marker.group(1)[0]
            if fence is None:
                fence = kind
            elif kind == fence:
                fence = None
            continue
        if fence is None:
            visible.append(re.sub(r"`+[^`]*`+", "", line))
    visible_text = "\n".join(visible)
    return [match.group(1).strip("<>") for pattern in (_INLINE_LINK, _REFERENCE)
            for match in pattern.finditer(visible_text)]


class SetupValidator:
    def __init__(self, repo_root, memory_root, codex_home, agents_home):
        self.repo = Path(repo_root).expanduser().resolve()
        self.memory = Path(memory_root).expanduser().resolve()
        self.codex = Path(codex_home).expanduser().absolute()
        self.agents = Path(agents_home).expanduser().absolute()
        self.checks = []

    def add(self, check_id, status, message):
        self.checks.append({"id": scan_text(check_id)["redacted_text"], "status": status,
                            "message": scan_text(message)["redacted_text"]})

    def load_json(self, path, check_id):
        try:
            return json.loads(path.read_text())
        except (OSError, ValueError, UnicodeError):
            self.add(check_id, "FAIL", "Required JSON file is missing or malformed.")
            return None

    def load_toml(self, path, check_id):
        if tomllib is None:
            self.add(check_id, "FAIL", "TOML validation requires Python 3.11 or newer.")
            return None
        try:
            return tomllib.loads(path.read_text())
        except (OSError, ValueError, UnicodeError):
            self.add(check_id, "FAIL", "TOML file is missing or malformed.")
            return None

    def link(self, target, source, check_id):
        try:
            valid = target.is_symlink() and source.exists() and target.resolve(strict=True) == source.resolve(strict=True)
        except (OSError, RuntimeError):
            valid = False
        self.add(check_id, "PASS" if valid else "FAIL",
                 "Entrypoint links to the authored source." if valid else "Entrypoint is missing, dangling, or points outside the authored source.")

    def skills(self):
        for name, entrypoint in OWNED_SKILLS.items():
            directory = self.repo / "skills" / name
            skill = directory / "SKILL.md"
            prefix = "skill." + name
            try:
                text = skill.read_text()
                match = re.match(r"\A---\s*\n([\s\S]*?)\n---\s*(?:\n|\Z)", text)
                if not match:
                    raise ValueError("frontmatter required")
                values = yaml_mapping(match.group(1))
                valid = values.get("name") == name and isinstance(values.get("description"), str) and bool(values["description"].strip()) and len(values["description"]) <= 1024
                if not valid:
                    raise ValueError("required scalar metadata invalid")
                self.add(prefix + ".frontmatter", "PASS", "Owned name and nonempty description are valid.")
            except (OSError, ValueError, UnicodeError):
                self.add(prefix + ".frontmatter", "FAIL", "SKILL.md needs valid YAML frontmatter with its owned name and a nonempty string description.")
            try:
                metadata = yaml_mapping((directory / "agents" / "openai.yaml").read_text())
                interface = metadata.get("interface", {})
                valid = isinstance(interface, dict) and all(isinstance(interface.get(key), str) and interface[key].strip()
                                                           for key in ("display_name", "short_description"))
                policy = metadata.get("policy", {})
                valid = valid and isinstance(policy, dict) and isinstance(policy.get("allow_implicit_invocation", True), bool)
                if not valid:
                    raise ValueError("invalid UI metadata")
                self.add(prefix + ".metadata", "PASS", "Skill interface and invocation metadata are valid.")
            except (OSError, ValueError, UnicodeError):
                self.add(prefix + ".metadata", "FAIL", "agents/openai.yaml is missing or has invalid interface/invocation metadata.")
            broken = 0
            for document in sorted(directory.rglob("*.md")):
                try:
                    targets = markdown_targets(document.read_text())
                    for target in targets:
                        parsed = urlsplit(target)
                        if parsed.scheme or parsed.netloc or not parsed.path or parsed.path.startswith(("/", "~")):
                            continue
                        resolved = (document.parent / unquote(parsed.path)).resolve()
                        if not resolved.is_relative_to(self.repo) or not resolved.exists():
                            broken += 1
                except (OSError, UnicodeError, ValueError, RuntimeError):
                    broken += 1
            self.add(prefix + ".references", "FAIL" if broken else "PASS",
                     f"{broken} missing, escaping, or unreadable relative Markdown references." if broken else "Relative Markdown references resolve within the repository.")
            script = directory / "scripts" / entrypoint
            exists = script.is_file() and os.access(script, os.X_OK)
            self.add(prefix + ".executable", "PASS" if exists else "FAIL",
                     "Owned entrypoint is executable." if exists else "Owned script entrypoint is missing or not executable.")
            if exists and shutil.which("bash"):
                result = subprocess.run(["bash", "-n", str(script)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self.add(prefix + ".syntax", "PASS" if result.returncode == 0 else "FAIL",
                         "Bash syntax is valid." if result.returncode == 0 else "Bash syntax validation failed.")

    def configuration(self):
        desired = self.load_json(self.repo / "config/desired-state.json", "config.desired")
        if desired is not None:
            valid = isinstance(desired, dict) and desired.get("schema_version") == 1
            valid = valid and isinstance(desired.get("required_features"), dict) and desired["required_features"].get("hooks") is True
            valid = valid and all(isinstance(value, bool) for value in desired.get("required_features", {}).values())
            valid = valid and isinstance(desired.get("deprecated_feature_keys", []), list)
            self.add("config.desired", "PASS" if valid else "FAIL", "Desired-state schema is valid." if valid else "Desired-state schema or owned hooks feature is invalid.")
            if not valid:
                desired = None
        hooks = self.load_json(self.repo / "config/hooks.json", "config.hooks")
        if hooks is not None:
            groups = hooks.get("hooks") if isinstance(hooks, dict) else None
            valid = isinstance(groups, dict) and bool(groups)
            if valid:
                for event, entries in groups.items():
                    valid = valid and isinstance(event, str) and isinstance(entries, list) and bool(entries)
                    if not isinstance(entries, list):
                        continue
                    for entry in entries:
                        if not isinstance(entry, dict):
                            valid = False
                            continue
                        valid = valid and isinstance(entry.get("matcher", ""), str) and isinstance(entry.get("hooks"), list) and bool(entry.get("hooks"))
                        for command in entry.get("hooks", []) if isinstance(entry.get("hooks"), list) else []:
                            if not isinstance(command, dict):
                                valid = False
                                continue
                            valid = valid and command.get("type") == "command" and isinstance(command.get("command"), str) and bool(command.get("command", "").strip())
                            for key in ("timeout", "additionalContextLimit"):
                                if key in command:
                                    valid = valid and isinstance(command[key], (int, float)) and not isinstance(command[key], bool) and (command[key] > 0 if key == "timeout" else command[key] >= 0)
                            if "async" in command:
                                valid = valid and isinstance(command["async"], bool)
            self.add("config.hooks", "PASS" if valid else "FAIL", "Authored command-hook schema is valid." if valid else "Authored hook groups or command definitions have invalid types.")
        mapping = self.load_json(self.repo / "config/project-map.json", "config.project-map")
        if mapping is not None:
            valid = isinstance(mapping, list) and all(isinstance(item, dict) and isinstance(item.get("root"), str) and bool(item["root"])
                                                     and isinstance(item.get("project"), str) and bool(item["project"])
                                                     and "/" not in item["project"] and ".." not in item["project"] for item in mapping)
            self.add("config.project-map", "PASS" if valid else "FAIL", "Project-map schema is valid." if valid else "Project-map entries must provide a root and a safe project identifier.")
        for filename, name in OWNED_AGENTS.items():
            values = self.load_toml(self.repo / "config/agents" / filename, "agent." + name)
            if values is not None:
                valid = values.get("name") == name and all(isinstance(values.get(key), str) and values[key].strip() for key in ("description", "developer_instructions"))
                if "sandbox_mode" in values:
                    valid = valid and values["sandbox_mode"] in ("read-only", "workspace-write", "danger-full-access")
                self.add("agent." + name, "PASS" if valid else "FAIL", "Authored agent name and required TOML fields are valid." if valid else "Authored agent identity, instructions, or sandbox mode is invalid.")
            self.link(self.codex / "agents" / filename, self.repo / "config/agents" / filename, "symlink.agent." + name)
        example = self.repo / "config/permissions.example.toml"
        if example.exists():
            values = self.load_toml(example, "config.permissions-example")
            if values is not None:
                valid = isinstance(values.get("default_permissions"), str) and isinstance(values.get("permissions"), dict)
                self.add("config.permissions-example", "PASS" if valid else "FAIL", "Optional permission example parses with named profiles." if valid else "Optional permission example requires a default profile and profile mapping.")
        runtime = self.codex / "config.toml"
        if runtime.exists():
            values = self.load_toml(runtime, "runtime.config")
            if values is not None:
                features = values.get("features", {})
                required = desired.get("required_features", {"hooks": True}) if desired else {"hooks": True}
                valid = isinstance(features, dict) and all(features.get(key) == value for key, value in required.items())
                self.add("runtime.owned-features", "PASS" if valid else "FAIL", "Owned runtime feature values match desired state." if valid else "Owned runtime feature values differ from desired state; unrelated values were not inspected for policy.")
                if isinstance(features, dict) and "js_repl" in features:
                    self.add("runtime.retired-feature", "WARN", "Retired js_repl feature key is present; reconcile the curated feature keys.")
                servers = values.get("mcp_servers", {})
                context7 = servers.get("context7", {}) if isinstance(servers, dict) else {}
                configured = isinstance(context7, dict) and context7.get("enabled", True) is not False and bool(context7.get("url") or context7.get("command"))
                self.add("dependency.context7", "PASS" if configured else "WARN", "Context7 is configured; static validation cannot establish whether it is callable." if configured else "Context7 is not configured as an enabled MCP server; use available primary documentation tools.")
        else:
            self.add("runtime.config", "FAIL", "Runtime config.toml is missing.")
            self.add("dependency.context7", "WARN", "Context7 configuration and runtime availability could not be established.")
        manifest = self.repo / "config/vendor-manifest.json"
        if manifest.exists():
            values = self.load_json(manifest, "vendor.manifest")
            if values is not None:
                valid = isinstance(values, dict) and values.get("schema_version") == 1
                valid = valid and isinstance(values.get("cli_version"), str) and isinstance(values.get("provenance"), str)
                valid = valid and isinstance(values.get("files"), dict) and bool(values.get("files"))
                drift = 0
                if valid:
                    for relative, digest in values["files"].items():
                        if not isinstance(relative, str) or not isinstance(digest, str) or re.fullmatch(r"[a-fA-F0-9]{64}", digest) is None:
                            valid = False
                            continue
                        try:
                            path = (self.repo / relative).resolve()
                            if Path(relative).is_absolute() or not path.is_relative_to(self.repo):
                                valid = False
                                continue
                            checksum = hashlib.sha256()
                            with path.open("rb") as stream:
                                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                                    checksum.update(chunk)
                            if checksum.hexdigest().lower() != digest.lower():
                                drift += 1
                        except (OSError, RuntimeError):
                            drift += 1
                self.add("vendor.manifest", "PASS" if valid else "FAIL", "Installed bundled-snapshot provenance schema is valid." if valid else "Vendor provenance schema or relative checksum targets are invalid.")
                if valid:
                    self.add("vendor.checksums", "WARN" if drift else "PASS", f"{drift} vendor files differ from the recorded snapshot; review upstream updates without resetting them." if drift else "Vendor files match the recorded installed snapshot.")
                    self.add("vendor.upstream-revision", "WARN", "Installed snapshot provenance does not establish an exact upstream revision.")
        else:
            self.add("vendor.manifest", "WARN", "Vendor provenance manifest is absent; vendor version verification was skipped.")

    def index(self):
        try:
            text = (self.memory / "index.md").read_text()
        except (OSError, UnicodeError):
            self.add("index.targets", "FAIL", "Memory index is missing or unreadable.")
            return
        for section in ("Projects", "Patterns", "Knowledge"):
            present = re.search(r"(?m)^## " + section + r"\s*$", text) is not None
            self.add("index.section." + section.lower(), "PASS" if present else "FAIL", "Required durable-anchor section exists." if present else "Required durable-anchor section is missing.")
        invalid = 0
        logs = bool(re.search(r"(?m)^##\s+Logs(?:\s|$)", text))
        for target in markdown_targets(text):
            try:
                parsed = urlsplit(target)
            except ValueError:
                invalid += 1
                continue
            if parsed.scheme or parsed.netloc:
                invalid += 1
                continue
            path = unquote(parsed.path)
            if not path:
                continue
            if Path(path).parts[:1] == ("logs",):
                logs = True
            try:
                resolved = (self.memory / path).resolve()
                inside = not Path(path).is_absolute() and resolved.is_relative_to(self.memory)
                if not inside or not resolved.exists():
                    invalid += 1
                elif resolved.relative_to(self.memory).parts[:1] == ("logs",):
                    logs = True
            except (OSError, RuntimeError):
                invalid += 1
        self.add("index.targets", "FAIL" if invalid else "PASS", f"{invalid} index targets are broken, external, or escape the memory root." if invalid else "Index targets exist within the memory root.")
        self.add("index.no-logs", "FAIL" if logs else "PASS", "Chronological logs must not be indexed." if logs else "Index contains no chronological log section or targets.")

    def run(self):
        self.add("runtime.python", "PASS" if sys.version_info >= (3, 11) else "FAIL", "Python 3.11 or newer is available." if sys.version_info >= (3, 11) else "Python 3.11 or newer is required.")
        self.add("dependency.rg", "PASS" if shutil.which("rg") else "WARN", "ripgrep is available." if shutil.which("rg") else "ripgrep is absent; search helpers use their slower fallback.")
        self.link(self.codex / "AGENTS.md", self.repo / "AGENTS.md", "symlink.instructions")
        self.link(self.codex / "skills", self.repo / "skills", "symlink.skills-legacy")
        self.link(self.agents / "skills", self.repo / "skills", "symlink.skills-canonical")
        self.link(self.codex / "hooks.json", self.repo / "config/hooks.json", "symlink.hooks")
        self.link(self.codex / "control-plane-hook.py", self.repo / "hooks/control_plane.py", "symlink.hook-launcher")
        self.skills()
        self.configuration()
        self.index()
        self.add("hooks.trust", "WARN", "Static validation cannot verify hook-definition trust; review current definitions through /hooks.")
        return {"checks": self.checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--memory-root", type=Path)
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    parser.add_argument("--agents-home", type=Path, default=Path.home() / ".agents")
    args = parser.parse_args()
    try:
        report = SetupValidator(args.repo_root, args.memory_root or args.repo_root / "memory", args.codex_home, args.agents_home).run()
    except Exception:
        # Do not expose parser exceptions, file contents, or credential paths.
        report = {"checks": [{"id": "validation.internal", "status": "FAIL", "message": "Setup validation could not complete; inspect the authored files locally."}]}
    print(json.dumps(report, indent=2))
    return int(any(check["status"] == "FAIL" for check in report["checks"]))


if __name__ == "__main__":
    raise SystemExit(main())
