"""Regression checks for cooperating concurrent memory writers (no live memory)."""

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lib"))
from memory_transaction import FD_ENV, LOCK_NAME, memory_lock, publish_file


class MemoryTransactionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="codex-memory-transactions-")
        self.addCleanup(self.fixture.cleanup)
        self.memory = Path(self.fixture.name) / "memory"
        self.environment = os.environ.copy()
        self.environment.pop(FD_ENV, None)
        self.environment.pop("MEMORY_TRANSACTION_TIMEOUT", None)
        self.environment["MEMORY_ROOT"] = str(self.memory)

    def command(self, skill, *args, env=None, pass_fds=()):
        script = REPO_ROOT / "skills" / skill / "scripts" / {
            "memory-write": "write.sh", "project-update": "update.sh",
            "decision-record": "record.sh", "memory-index-update": "update_index.sh",
            "runbook-create": "create.sh", "workflow-plan": "plan.sh",
        }[skill]
        return subprocess.run(
            ["bash", str(script), *args], env=env or self.environment,
            pass_fds=pass_fds, text=True, capture_output=True, timeout=60,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def parallel(self, calls):
        # Submit every invocation before awaiting results: these compete for one
        # root, rather than repeatedly exercising a sequential write path.
        with ThreadPoolExecutor(max_workers=24) as pool:
            futures = [pool.submit(self.command, *call) for call in calls]
            for future in futures:
                self.assert_success(future.result())

    def test_twenty_four_concurrent_index_updates_retain_every_link(self):
        self.parallel([
            ("memory-write", "--type", "knowledge", "--title", f"Knowledge fixture {n}",
             "--body", f"Reference fixture {n}", "--date", "2026-10-12")
            for n in range(24)
        ])
        index = (self.memory / "index.md").read_text()
        pages = list((self.memory / "knowledge").glob("*.md"))
        self.assertEqual(len(pages), 24)
        for n in range(24):
            relative = f"knowledge/knowledge-fixture-{n}.md"
            self.assertEqual(index.count(f"]({relative})"), 1)
            self.assertIn(f"Reference fixture {n}", (self.memory / relative).read_text())
        self.assertFalse(list(self.memory.glob(".index.md.*")))

    def test_twenty_four_concurrent_decisions_are_unique_and_immutable(self):
        decisions = self.memory / "decisions"
        decisions.mkdir(parents=True)
        prior = decisions / "2026-10-shared-fixture.md"
        prior.write_text("# Prior decision\n\nRetain this exact content.\n")
        original = prior.read_bytes()
        calls = []
        for n in range(24):
            common = ("--title", "Shared fixture", "--date", "2026-10-12")
            if n % 2:
                calls.append(("memory-write", "--type", "decision", *common,
                              "--body", f"Fixture choice {n}"))
            else:
                calls.append(("decision-record", *common, "--decision", f"Fixture choice {n}",
                              "--context", "Fixture context", "--why", "Fixture rationale",
                              "--tradeoffs", "Fixture cost", "--followups", ""))
        self.parallel(calls)
        self.assertEqual(prior.read_bytes(), original)
        pages = list(decisions.glob("*.md"))
        self.assertEqual(len(pages), 25)
        choices = []
        for page in pages:
            if page == prior:
                continue
            body = page.read_text()
            for section in ("Context", "Decision", "Tradeoffs", "Follow-ups"):
                self.assertIn(f"## {section}\n", body)
            choices.extend(int(n) for n in re.findall(r"Fixture choice (\d+)", body))
        self.assertCountEqual(choices, range(24))

    def test_twenty_four_mixed_project_writes_keep_complete_entries_and_plans(self):
        calls = []
        for n in range(24):
            if n % 3 == 0:
                calls.append(("memory-write", "--type", "project", "--project", "Shared project",
                              "--title", f"Update {n}", "--status", "in progress",
                              "--body", f"Project fixture {n}", "--next", f"Next fixture {n}",
                              "--date", "2026-10-12"))
            elif n % 3 == 1:
                calls.append(("project-update", "--project", "Shared project", "--title", f"Update {n}",
                              "--status", "in progress", "--notes", f"Project fixture {n}",
                              "--next", f"Next fixture {n}", "--date", "2026-10-12", "--time", "12:00"))
            else:
                calls.append(("workflow-plan", "--project", "Shared project", "--title", "Concurrent plan",
                              "--goal", f"Plan fixture {n}", "--date", "2026-10-12", "--time", "12:00"))
        self.parallel(calls)
        project = self.memory / "projects" / "shared-project"
        body = (project / "log.md").read_text()
        entries = re.split(r"(?m)^## ", body)[1:]
        self.assertEqual(len(entries), 24)
        for entry in entries:
            self.assertEqual(entry.count("Status: "), 1)
            self.assertEqual(entry.count("Notes:\n"), 1)
            self.assertEqual(entry.count("Next:\n"), 1)
        for n in range(24):
            marker = f"Plan fixture {n}" if n % 3 == 2 else f"Project fixture {n}"
            self.assertEqual(len(re.findall(re.escape(marker) + r"(?=\n)", body)), 1)
        plans = list((project / "plans").glob("*.md"))
        self.assertEqual(len(plans), 8)
        for plan in plans:
            text = plan.read_text()
            for section in ("Constraints", "Acceptance Criteria", "Execution Steps", "Verification", "Rollback", "Risks"):
                self.assertIn(f"## {section}\n", text)
            self.assertIn(str(plan.relative_to(self.memory)), body)
        self.assertTrue((project / "overview.md").is_file())
        self.assertEqual((self.memory / "index.md").read_text().count("](" + "projects/shared-project/overview.md)"), 1)

    def test_twenty_four_nested_runbook_writes_retain_files_and_index(self):
        self.parallel([
            ("runbook-create", "--title", "Shared runbook", "--when-to-use", f"Fixture use {n}",
             "--steps", f"Fixture step {n}", "--verification", "Check fixture",
             "--failure-modes", "Fixture unavailable", "--date", "2026-10-12")
            for n in range(24)
        ])
        pages = list((self.memory / "patterns").glob("*.md"))
        self.assertEqual(len(pages), 24)
        index = (self.memory / "index.md").read_text()
        uses = []
        for page in pages:
            uses.extend(int(n) for n in re.findall(r"Fixture use (\d+)", page.read_text()))
            self.assertEqual(index.count(f"](patterns/{page.name})"), 1)
        self.assertCountEqual(uses, range(24))

    def test_nested_writer_reuses_verified_descriptor(self):
        with memory_lock(self.memory) as fd:
            env = self.environment | {FD_ENV: str(fd), "MEMORY_TRANSACTION_TIMEOUT": "0.1"}
            result = self.command("workflow-plan", "--goal", "Nested fixture", "--project", "nested",
                                  env=env, pass_fds=(fd,))
            self.assert_success(result)
        self.assertTrue((self.memory / "projects/nested/log.md").is_file())

    def test_forged_environment_cannot_skip_lock(self):
        with memory_lock(self.memory):
            env = self.environment | {FD_ENV: "9999", "MEMORY_TRANSACTION_TIMEOUT": "0.1"}
            result = self.command("memory-write", "--type", "log", "--title", "Blocked fixture", env=env)
            self.assertEqual(result.returncode, 4)
            self.assertIn("timed out", result.stderr)
            self.assertFalse((self.memory / "logs").exists())

    def test_separate_descriptor_for_same_file_cannot_skip_owner(self):
        with memory_lock(self.memory):
            fd = os.open(self.memory / LOCK_NAME, os.O_RDWR)
            try:
                env = self.environment | {FD_ENV: str(fd), "MEMORY_TRANSACTION_TIMEOUT": "0.1"}
                result = self.command("memory-write", "--type", "log", "--title", "Blocked fixture",
                                      env=env, pass_fds=(fd,))
                self.assertEqual(result.returncode, 4)
                self.assertFalse((self.memory / "logs").exists())
            finally:
                os.close(fd)

    def test_different_root_and_symlink_alias_use_correct_lock(self):
        self.memory.mkdir()
        alias = Path(self.fixture.name) / "alias"
        alias.symlink_to(self.memory, target_is_directory=True)
        with memory_lock(self.memory):
            env = self.environment | {"MEMORY_ROOT": str(alias), "MEMORY_TRANSACTION_TIMEOUT": "0.1"}
            blocked = self.command("memory-write", "--type", "log", "--title", "Alias fixture", env=env)
            self.assertEqual(blocked.returncode, 4)
            env["MEMORY_ROOT"] = str(Path(self.fixture.name) / "other")
            self.assert_success(self.command("memory-write", "--type", "log", "--title", "Independent fixture", env=env))

    def test_kernel_releases_lock_when_owner_is_killed(self):
        env = self.environment | {"PYTHONPATH": str(REPO_ROOT / "lib")}
        owner = subprocess.Popen([
            sys.executable, "-u", "-c",
            "import sys,time; from memory_transaction import memory_lock; "
            "\nwith memory_lock(sys.argv[1]):\n print('ready', flush=True)\n time.sleep(60)",
            str(self.memory),
        ], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(owner.stdout.readline().strip(), "ready")
            owner.kill()
            owner.wait(timeout=5)
            env["MEMORY_TRANSACTION_TIMEOUT"] = "0.1"
            self.assert_success(self.command("memory-write", "--type", "log", "--title", "Recovered fixture", env=env))
        finally:
            if owner.poll() is None:
                owner.kill()
                owner.wait(timeout=5)
            owner.stdout.close()
            owner.stderr.close()

    def test_publication_never_clobbers_and_replacement_keeps_mode(self):
        self.memory.mkdir()
        target = self.memory / "entry.md"
        publish_file(target, b"Original complete entry\n")
        with self.assertRaises(FileExistsError):
            publish_file(target, b"Overwriting entry\n")
        self.assertEqual(target.read_bytes(), b"Original complete entry\n")
        target.chmod(0o640)
        publish_file(target, b"Replacement complete entry\n", replace=True)
        self.assertEqual(target.read_bytes(), b"Replacement complete entry\n")
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)
        self.assertEqual(list(self.memory.iterdir()), [target])

    def test_help_and_secret_rejection_leave_memory_untouched(self):
        self.assert_success(self.command("memory-write", "--help"))
        self.assertFalse(self.memory.exists())
        # A synthetic scanner fixture, constructed rather than a credential.
        sensitive = "sk-" + "x" * 24
        blocked = self.command("memory-write", "--type", "log", "--title", "Scanner fixture", "--body", sensitive)
        self.assertEqual(blocked.returncode, 3)
        self.assertNotIn(sensitive, blocked.stdout + blocked.stderr)
        self.assertFalse(self.memory.exists())
        redacted = self.command("memory-write", "--type", "log", "--title", "Scanner fixture",
                                "--body", sensitive, "--allow-redact", "--date", "2026-10-12")
        self.assert_success(redacted)
        saved = (self.memory / "logs/2026/10-12.md").read_text()
        self.assertNotIn(sensitive, saved)
        self.assertIn("[REDACTED]", saved)

    def test_pattern_plan_indexes_and_invalid_timeout_fails_closed(self):
        self.assert_success(self.command("workflow-plan", "--to-pattern", "--goal", "Pattern fixture"))
        page = next((self.memory / "patterns").glob("*.md"))
        self.assertIn(f"](patterns/{page.name})", (self.memory / "index.md").read_text())
        env = self.environment | {"MEMORY_TRANSACTION_TIMEOUT": "nan"}
        result = self.command("memory-write", "--type", "log", "--title", "Invalid timeout fixture", env=env)
        self.assertEqual(result.returncode, 4)
        self.assertFalse((self.memory / "logs").exists())


if __name__ == "__main__":
    unittest.main()
