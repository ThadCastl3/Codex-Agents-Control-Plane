#!/usr/bin/env python3
"""Reconcile owned entrypoints without replacing desktop-managed configuration."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib

from memory_transaction import memory_lock, publish_file


def config_text(text, desired):
    """Edit only owned feature keys, preserving other TOML and comments."""
    current = tomllib.loads(text)
    if current.get("hooks"):
        raise ValueError("inline hooks already exist; reconcile hook sources before installation")
    features = current.get("features", {})
    lines = text.splitlines(keepends=True)
    header = re.compile(r"^\s*\[\[?([^\]]+)\]\]?\s*(?:#.*)?$")
    starts = [i for i, line in enumerate(lines) if header.match(line) and header.match(line).group(1) == "features"]
    required = desired.get("required_features", {})
    deprecated = set(desired.get("deprecated_feature_keys", []))
    if any(key.startswith("features.") for key in current):
        raise ValueError("unsupported features layout")
    if "features" in current and not starts:
        # Inline/dotted tables need an explicit migration, not a second table.
        if any(key in features for key in deprecated) or any(features.get(key) != value for key, value in required.items()):
            raise ValueError("features must use a standalone [features] table for curated reconciliation")
        return text
    if starts:
        start = starts[0]
        end = next((i for i in range(start + 1, len(lines)) if header.match(lines[i])), len(lines))
        body = []
        seen = set()
        for line in lines[start + 1:end]:
            match = re.match(r'^\s*([A-Za-z0-9_-]+)\s*=', line)
            key = match.group(1) if match else None
            if key in deprecated:
                continue
            if key in required:
                seen.add(key)
                if features.get(key) != required[key]:
                    comment = " " + line[line.index("#"):].rstrip() if "#" in line else ""
                    line = f'{key} = {str(required[key]).lower()}{comment}\n'
            body.append(line)
        for key, value in required.items():
            if key not in seen:
                body.append(f'{key} = {str(value).lower()}\n')
        lines[start + 1:end] = body
        updated = "".join(lines)
    else:
        updated = text.rstrip() + "\n\n[features]\n" + "".join(f'{key} = {str(value).lower()}\n' for key, value in required.items())
    parsed = tomllib.loads(updated)
    expected = dict(features)
    for key in deprecated:
        expected.pop(key, None)
    expected.update(required)
    untouched = dict(current)
    untouched["features"] = expected
    if parsed != untouched:
        raise ValueError("curated config reconciliation changed unrelated values")
    return updated


class Installer:
    def __init__(self, repo, codex_home, agents_home, dry_run=False, suffix=None):
        self.repo = repo.resolve()
        self.codex_home = codex_home.expanduser().absolute()
        self.agents_home = agents_home.expanduser().absolute()
        self.dry_run = dry_run
        self.suffix = suffix or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", self.suffix):
            raise ValueError("backup suffix must contain only letters, digits, dots, underscores, or hyphens")
        self.actions = []

    def backup(self, target, resolved_content=False):
        directory = self.repo / ".private" / "install-backups"
        name = self.suffix + "-" + hashlib.sha256(str(target).encode()).hexdigest()[:12] + "-" + target.name
        backup = directory / name
        count = 2
        while backup.exists() or backup.is_symlink():
            backup = directory / (name + f"-{count}")
            count += 1
        if not self.dry_run:
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            directory.chmod(0o700)
            if target.is_symlink() and not resolved_content:
                backup.symlink_to(os.readlink(target))
            elif target.is_dir():
                shutil.copytree(target, backup, symlinks=True)
            else:
                shutil.copy2(target, backup)
                backup.chmod(0o600)
            publish_file(directory / (backup.name + ".restore.json"), json.dumps({"target": str(target), "backup": str(backup)}).encode())
        self.actions.append({"action": "backup", "target": str(target), "backup": str(backup)})
        return backup

    def link(self, target, source, preserve_foreign=False):
        source = source.resolve(strict=True)
        if target.is_symlink() and target.resolve() == source:
            self.actions.append({"action": "already-linked", "target": str(target)})
            return
        if target.exists() or target.is_symlink():
            if preserve_foreign:
                raise ValueError(f"existing hook source preserved at {target}; merge it before installing this source")
            self.backup(target)
        self.actions.append({"action": "link", "target": str(target), "source": str(source)})
        if not self.dry_run:
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            elif target.exists() or target.is_symlink():
                target.unlink()
            target.symlink_to(source)

    def install(self, reconcile_config=True):
        desired = json.loads((self.repo / "config" / "desired-state.json").read_text())
        config = self.codex_home / "config.toml"
        original = config.read_text() if config.exists() else ""
        updated = config_text(original, desired) if reconcile_config else original
        # Preflight hook conflicts before changing any other entrypoint.
        hooks = self.codex_home / "hooks.json"
        hooks_source = (self.repo / "config" / "hooks.json").resolve(strict=True)
        if (hooks.exists() or hooks.is_symlink()) and not (hooks.is_symlink() and hooks.resolve() == hooks_source):
            raise ValueError("existing hooks.json preserved; merge hook sources before installation")
        for directory in (self.codex_home, self.agents_home):
            if directory.exists() and not directory.is_dir():
                raise ValueError(f"entrypoint parent is not a directory: {directory}")
        self.link(self.codex_home / "AGENTS.md", self.repo / "AGENTS.md")
        self.link(self.codex_home / "skills", self.repo / "skills")
        self.link(self.agents_home / "skills", self.repo / "skills")
        self.link(self.codex_home / "control-plane-hook.py", self.repo / "hooks" / "control_plane.py")
        self.link(hooks, hooks_source, preserve_foreign=True)
        for source in sorted((self.repo / "config" / "agents").glob("*.toml")):
            self.link(self.codex_home / "agents" / source.name, source)
        if updated != original:
            if config.exists():
                self.backup(config, resolved_content=True)
            self.actions.append({"action": "reconcile-owned-features", "target": str(config)})
            if not self.dry_run:
                publish_file(config.resolve(), updated.encode(), replace=config.exists())
        return self.actions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    parser.add_argument("--agents-home", type=Path, default=Path.home() / ".agents")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--skip-doctor", action="store_true")
    parser.add_argument("--skip-config", action="store_true")
    parser.add_argument("--backup-suffix")
    args = parser.parse_args()
    try:
        installer = Installer(args.repo_root, args.codex_home, args.agents_home, args.dry_run, args.backup_suffix)
        if args.dry_run:
            actions = installer.install(not args.skip_config)
        else:
            private = args.repo_root / ".private"
            private.mkdir(parents=True, exist_ok=True, mode=0o700)
            private.chmod(0o700)
            with memory_lock(private / "setup", timeout=30):
                actions = installer.install(not args.skip_config)
        print(json.dumps({"dry_run": args.dry_run, "actions": actions, "hook_trust": "review current definitions through /hooks; installation does not grant trust"}, indent=2))
        if not args.skip_doctor and not args.dry_run:
            return subprocess.call([str(args.repo_root / "bin" / "doctor.sh"), "--repo-root", str(args.repo_root), "--codex-home", str(args.codex_home), "--agents-home", str(args.agents_home)])
        return 0
    except (OSError, ValueError, TimeoutError) as exc:
        from secret_scan import scan_text
        print(scan_text(f"Install failed: {exc}")["redacted_text"], file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
