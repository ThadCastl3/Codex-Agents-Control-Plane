#!/usr/bin/env python3
"""Serialize cooperating memory writers on macOS and Linux.

``with memory_lock(root, timeout=30) as fd:`` holds a kernel advisory lock
until the context exits. No PID or environment flag can grant lock ownership.
The CLI passes the locked descriptor to a writer and its nested scripts; they
verify the descriptor's inode and acquire its exclusive lock before reusing it.
Locks survive in-flight children and release when the last descriptor closes.
The persistent lock file must never be deleted as a stale-lock remedy.

This provides serialization, not rollback of a partially failed multi-file
operation. All writers of the same memory root must use this helper.
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
from typing import Iterator

LOCK_NAME = ".memory-transaction.lock"
FD_ENV = "CODEX_MEMORY_TRANSACTION_FD"
TIMEOUT_ENV = "MEMORY_TRANSACTION_TIMEOUT"


class LockTimeout(TimeoutError):
    """A cooperating writer did not release its lock before the deadline."""


def _lock_path(root: str | os.PathLike[str]) -> Path:
    return Path(root).expanduser().resolve() / LOCK_NAME


def inherited_lock_fd(root: str | os.PathLike[str]) -> int | None:
    """Return an inherited descriptor only after verifying actual lock ownership.

    An arbitrary environment value, stale descriptor, descriptor for a different
    root, or unlocked descriptor competing with another owner cannot bypass the
    lock. flock on an inherited open-file description preserves its existing
    lock. If no owner exists, it safely acquires the lock on that description.
    """
    try:
        fd = int(os.environ[FD_ENV])
        if fd < 3:
            return None
        opened = os.fstat(fd)
        expected = os.stat(_lock_path(root), follow_symlinks=False)
        if not stat.S_ISREG(expected.st_mode):
            return None
        if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
            return None
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (KeyError, ValueError, OSError):
        return None


@contextlib.contextmanager
def memory_lock(root: str | os.PathLike[str], timeout: float = 30) -> Iterator[int]:
    """Hold a per-root exclusive lock; yield its descriptor for subprocess use.

    For a nested subprocess, pass ``fd`` in ``pass_fds`` and set
    ``CODEX_MEMORY_TRANSACTION_FD=str(fd)`` in its environment. Reuse is verified
    from the descriptor itself. Without both, a nested writer waits like any
    other independent writer. The timeout is in seconds; zero means fail fast.
    A leftover lock file is harmless: the kernel, not its contents, owns locks.
    """
    if not math.isfinite(timeout) or timeout < 0:
        raise ValueError("lock timeout must be a finite nonnegative number")
    inherited = inherited_lock_fd(root)
    if inherited is not None:
        yield inherited
        return  # The outer owner must retain the lock.

    path = _lock_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise OSError("memory lock must be a regular file")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as exc:
                if exc.errno not in (errno.EACCES, errno.EAGAIN):
                    raise
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise LockTimeout("timed out waiting for the memory transaction lock") from None
                time.sleep(min(0.05, remaining))
        yield fd
    finally:
        os.close(fd)


def publish_file(destination: str | os.PathLike[str], data: bytes, *, replace: bool = False) -> None:
    """Publish complete content from a private temp file on the same filesystem.

    Creation uses link(2) so an existing destination is never overwritten.
    Replacement uses rename(2) and preserves existing permission bits. Callers
    must hold memory_lock when publishing as part of a read/modify/write flow.
    """
    target = Path(destination)
    fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            if target.exists():
                os.chmod(temporary, stat.S_IMODE(target.stat().st_mode))
            os.replace(temporary, target)
        else:
            os.link(temporary, target)  # Atomic no-clobber publication.
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--root", required=True)
    run = commands.add_parser("run")
    run.add_argument("--root", required=True)
    run.add_argument("--timeout", type=float, default=None)
    run.add_argument("command", nargs=argparse.REMAINDER)
    publish = commands.add_parser("publish")
    mode = publish.add_mutually_exclusive_group(required=True)
    mode.add_argument("--create", metavar="PATH")
    mode.add_argument("--replace", metavar="PATH")
    args = parser.parse_args()
    if args.operation == "validate":
        return 0 if inherited_lock_fd(args.root) is not None else 1
    try:
        if args.operation == "publish":
            publish_file(args.create or args.replace, sys.stdin.buffer.read(), replace=args.replace is not None)
            return 0
        command = args.command
        if command[:1] == ["--"]:
            command = command[1:]
        if not command:
            parser.error("run requires a command")
        timeout = args.timeout
        if timeout is None:
            timeout = float(os.environ.get(TIMEOUT_ENV, "30"))
        with memory_lock(args.root, timeout=timeout) as fd:
            env = os.environ.copy()
            env[FD_ENV] = str(fd)
            result = subprocess.run(command, env=env, pass_fds=(fd,), check=False)
            return result.returncode if result.returncode >= 0 else 128 - result.returncode
    except (OSError, ValueError) as exc:
        # Do not include the command, argv fields, or file contents in errors.
        print(f"Error: memory transaction failed: {exc.strerror if isinstance(exc, OSError) and exc.strerror else exc}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
