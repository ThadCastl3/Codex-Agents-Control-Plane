#!/usr/bin/env python3
"""Private scanned Markdown snapshots; restore preserves the live lock inode."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import uuid

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "lib"))
from memory_transaction import LOCK_NAME, memory_lock, publish_file
from secret_scan import scan_text


def validate_member(relative):
    if not isinstance(relative, str) or any(ord(char) < 32 for char in relative) or "\\" in relative:
        raise ValueError("invalid snapshot member path")
    parts = PurePosixPath(relative)
    if parts.is_absolute() or ".." in parts.parts or parts.suffix != ".md" or any(part.startswith(".") for part in parts.parts):
        raise ValueError("invalid snapshot member path")
    if scan_text(relative, mode="write")["status"] != "pass":
        raise ValueError("snapshot refuses sensitive document paths")
    return parts


def documents(memory, allow_redact=False):
    result = {}
    redacted = 0
    paths = []

    def walk_error(error):
        raise error

    for directory, directories, filenames in os.walk(memory, topdown=True, followlinks=False, onerror=walk_error):
        directories[:] = sorted(name for name in directories if not name.startswith("."))
        for name in directories:
            if (Path(directory) / name).is_symlink():
                raise ValueError("snapshot refuses symlinked memory directories")
        for name in sorted(filenames):
            if name.startswith(".") or not name.endswith(".md"):
                continue
            paths.append((Path(directory) / name).relative_to(memory).as_posix())
    for relative in sorted(paths):
        path = checked_destination(memory, relative)
        checked = scan_text(path.read_text(), mode="write", allow_redact=allow_redact)
        if checked["status"] == "blocked":
            raise ValueError("snapshot blocked by secret policy; explicit --allow-redact can save a sanitized copy")
        redacted += checked["status"] == "redacted"
        result[relative] = checked["redacted_text"].encode()
    return result, redacted


def checked_destination(memory, relative):
    """Check every existing component without traversing a symlink.

    Call before each mutation, including rollback. The writer lock serializes
    cooperating changes; this check also refuses an observed external change.
    """
    parts = validate_member(relative).parts
    if memory.is_symlink() or not memory.is_dir():
        raise ValueError("memory root is missing or symlinked")
    current = memory
    for position, component in enumerate(parts):
        current = current / component
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(mode):
            raise ValueError("snapshot destination is symlinked")
        if position < len(parts) - 1:
            if not stat.S_ISDIR(mode):
                raise ValueError("snapshot destination parent is not a directory")
        elif not stat.S_ISREG(mode):
            raise ValueError("snapshot destination is not a regular file")
    if not current.resolve().is_relative_to(memory.resolve()):
        raise ValueError("snapshot destination is outside memory")
    return current


def capture(memory, snapshots, allow_redact=False):
    contents, redacted = documents(memory, allow_redact)
    snapshots.mkdir(parents=True, exist_ok=True, mode=0o700)
    snapshots.chmod(0o700)
    name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:12]
    stage = snapshots / (".pending-" + name)
    stage.mkdir(mode=0o700)
    try:
        for relative, data in contents.items():
            destination = stage / "files" / relative
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            publish_file(destination, data)
        manifest = {"version": 1, "redacted_documents": redacted, "files": {relative: hashlib.sha256(data).hexdigest() for relative, data in contents.items()}}
        publish_file(stage / "manifest.json", json.dumps(manifest, indent=2).encode())
        stage.rename(snapshots / name)
    except BaseException:
        shutil.rmtree(stage)
        raise
    return name, contents, redacted


def load_snapshot(snapshots, name, allow_redact=False):
    if not name or Path(name).name != name or name.startswith("."):
        raise ValueError("snapshot must be a visible snapshot name from list")
    directory = snapshots / name
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("snapshot not found or symlinked")
    manifest_path = directory / "manifest.json"
    if manifest_path.is_symlink():
        raise ValueError("snapshot manifest is symlinked")
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, dict) or manifest.get("version") != 1 or not isinstance(manifest.get("files"), dict):
        raise ValueError("unsupported snapshot manifest")
    files = {}
    for relative, digest in manifest["files"].items():
        validate_member(relative)
        path = directory / "files" / relative
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent.is_relative_to(directory)):
            raise ValueError("snapshot member is symlinked")
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("snapshot integrity check failed")
        checked = scan_text(data.decode(), mode="write", allow_redact=allow_redact)
        if checked["status"] == "blocked":
            raise ValueError("restore blocked by secret policy")
        files[relative] = checked["redacted_text"].encode()
    return files


def restore(memory, snapshots, name, allow_redact=False):
    replacement = load_snapshot(snapshots, name, allow_redact)
    # Reject invalid destinations before touching any live document.
    for relative in replacement:
        checked_destination(memory, relative)
    # Capture recovery before mutation; refusing unsafe existing content leaves it intact.
    recovery, previous, _ = capture(memory, snapshots, allow_redact)
    existing = set(previous)
    changed = []
    try:
        for relative, data in replacement.items():
            destination = checked_destination(memory, relative)
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            checked_destination(memory, relative)
            publish_file(destination, data, replace=destination.exists())
            changed.append(relative)
        for relative in sorted(existing - set(replacement)):
            checked_destination(memory, relative).unlink()
            changed.append(relative)
    except BaseException as original_error:
        rollback_failed = False
        # Undo only successful mutations. Never unlink an unattempted path, and
        # recheck containment in case a parent changed after the initial scan.
        for relative in reversed(changed):
            try:
                destination = checked_destination(memory, relative)
                if relative in previous:
                    publish_file(destination, previous[relative], replace=destination.exists())
                elif destination.exists():
                    destination.unlink()
            except (OSError, ValueError):
                rollback_failed = True
        if rollback_failed:
            raise ValueError(f"restore failed and rollback was incomplete; recovery snapshot: {recovery}") from original_error
        raise
    return recovery, len(replacement)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["create", "list", "restore"])
    parser.add_argument("snapshot", nargs="?")
    parser.add_argument("--memory-root", type=Path, default=Path(os.environ.get("MEMORY_ROOT", str(REPO / "memory"))))
    parser.add_argument("--snapshot-root", type=Path, default=REPO / ".private" / "snapshots")
    parser.add_argument("--allow-redact", action="store_true")
    args = parser.parse_args()
    memory = args.memory_root.expanduser().resolve()
    snapshots = args.snapshot_root.expanduser().resolve()
    try:
        if snapshots.is_relative_to(memory):
            raise ValueError("snapshot storage must be outside memory")
        if args.action == "list":
            names = sorted(path.name for path in snapshots.iterdir() if path.is_dir() and not path.is_symlink() and not path.name.startswith(".")) if snapshots.exists() else []
            print(json.dumps({"snapshots": names}))
            return 0
        if not memory.is_dir():
            raise ValueError("memory root is missing")
        with memory_lock(memory):
            if args.action == "create":
                name, files, redacted = capture(memory, snapshots, args.allow_redact)
                print(json.dumps({"snapshot": name, "documents": len(files), "redacted_documents": redacted}))
            else:
                recovery, count = restore(memory, snapshots, args.snapshot, args.allow_redact)
                print(json.dumps({"restored": args.snapshot, "documents": count, "pre_restore_snapshot": recovery}))
        return 0
    except (OSError, ValueError, TimeoutError) as exc:
        print(scan_text(f"Snapshot operation failed: {exc}")["redacted_text"], file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
