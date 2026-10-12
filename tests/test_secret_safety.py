"""Behavioral safety checks with generated, inert fixtures and value-free failures."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("memory_secret_scan", REPO / "lib/secret_scan.py")
SCANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCANNER)
READERS = (
    "skills/memory-retrieve/scripts/retrieve.sh",
    "skills/decision-check/scripts/check.sh",
    "skills/project-status/scripts/status.sh",
    "skills/context-bootstrap/scripts/bootstrap.sh",
)


def cases():
    # Never use real credentials, and never attach these values to assertion messages.
    opaque = "q" * 40
    return (
        ("uppercase_assignment", "API_KEY=" + opaque, opaque, False),
        ("quoted_assignment", '"OPENAI_API_KEY": "' + opaque + ' spaced"', opaque, False),
        ("password_assignment", "PASSWORD='" + opaque + " spaced'", opaque, False),
        ("lowercase_bearer", "bearer " + opaque, opaque, True),
        ("uppercase_bearer", "BEARER " + opaque, opaque, True),
        ("multiline_bearer", "bEaReR\n" + opaque, opaque, True),
        ("project_api_key", "sk-proj-" + opaque, "sk-proj-" + opaque, True),
        ("service_api_key", "sk-svcacct-" + opaque, "sk-svcacct-" + opaque, True),
        ("classic_github", "ghp_" + opaque, "ghp_" + opaque, True),
        ("fine_github", "github_pat_" + opaque, "github_pat_" + opaque, True),
        ("jwt", "eyJ" + opaque + "." + opaque + "." + opaque, "eyJ" + opaque, False),
        ("hex", "9f" * 24, "9f" * 24, False),
        ("aws_temporary", "ASIA" + "Q" * 16, "ASIA" + "Q" * 16, True),
    )


class SecretSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="memory-secret-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_script(self, relative, args, memory=None, extra_env=None, stdin=None):
        env = dict(os.environ, MEMORY_ROOT=str(memory or self.root / "memory"))
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if extra_env:
            env.update(extra_env)
        return subprocess.run(["/bin/bash", str(REPO / relative), *args],
                              input=stdin, capture_output=True, text=True, env=env)

    def assert_absent(self, value, output, label):
        self.assertTrue(value not in output, "Sensitive fixture value remained: " + label)

    def test_scanner_read_and_write_policy_and_idempotence(self):
        for name, sample, value, high in cases():
            with self.subTest(case=name):
                read = SCANNER.scan_text(sample)
                self.assertEqual(read["status"], "redacted")
                self.assertEqual(read["high_conf"], high)
                self.assert_absent(value, read["redacted_text"], name)
                second = SCANNER.scan_text(read["redacted_text"])
                self.assertEqual(second["status"], "pass")
                self.assertTrue(second["redacted_text"] == read["redacted_text"], "Redaction changed on rescan")
                blocked = SCANNER.scan_text(sample, mode="write")
                self.assertEqual(blocked["status"], "blocked" if high else "redacted")
                allowed = SCANNER.scan_text(sample, mode="write", allow_redact=True)
                self.assertEqual(allowed["status"], "redacted")
                self.assert_absent(value, allowed["redacted_text"], name)

    def test_private_key_blocks_keep_source_line_numbers(self):
        payload = "private fixture payload " + "q" * 60
        for end in ("\n-----END OPENSSH PRIVATE KEY-----", ""):
            sample = "before\n-----BEGIN OPENSSH PRIVATE KEY-----\n" + payload + end + "\n"
            result = SCANNER.scan_text(sample)
            self.assertEqual(result["high_conf"], True)
            self.assert_absent(payload, result["redacted_text"], "private key block")
            self.assertEqual(result["redacted_text"].count("\n"), sample.count("\n"))
            self.assertEqual(SCANNER.scan_text(sample, mode="write")["status"], "blocked")

    def test_bash_scanner_cli_preserves_policy(self):
        for name, sample, value, high in cases():
            with self.subTest(case=name):
                result = self.run_script("skills/secret-scan/scripts/scan.sh", ["--stdin"], stdin=sample)
                self.assertEqual(result.returncode, 3 if high else 0)
                self.assert_absent(value, result.stdout + result.stderr, name)
                allowed = self.run_script("skills/secret-scan/scripts/scan.sh",
                                          ["--stdin", "--allow-redact"], stdin=sample)
                self.assertEqual(allowed.returncode, 0)
                self.assert_absent(value, allowed.stdout + allowed.stderr, name)

    def test_actual_writers_remove_detected_values(self):
        for name in ("uppercase_assignment", "lowercase_bearer", "project_api_key", "fine_github", "jwt"):
            _, sample, value, high = next(case for case in cases() if case[0] == name)
            memory = self.root / name
            args = ["--type", "knowledge", "--title", "Fixture note", "--body", sample]
            result = self.run_script("skills/memory-write/scripts/write.sh", args, memory)
            self.assertEqual(result.returncode, 3 if high else 0)
            if high:
                self.assertFalse(any((memory / "knowledge").glob("*.md")))
                result = self.run_script("skills/memory-write/scripts/write.sh",
                                         args + ["--allow-redact"], memory)
                self.assertEqual(result.returncode, 0)
            self.assert_absent(value, result.stdout + result.stderr, name)
            for path in memory.rglob("*.md"):
                self.assert_absent(value, path.read_text(), name)

    def make_reader_fixture(self, value, private_payload=None):
        memory = self.root / "memory"
        (memory / "knowledge").mkdir(parents=True)
        (memory / "decisions").mkdir()
        (memory / "projects" / "fixture").mkdir(parents=True)
        (memory / "index.md").write_text("# Memory Index\n")
        body = "The fixture topic value is " + value + "\n"
        if private_payload is not None:
            body += "-----BEGIN PRIVATE KEY-----\n" + private_payload + "\n-----END PRIVATE KEY-----\n"
        # The path is itself sensitive and must be sanitized in rendered output.
        (memory / "knowledge" / ("fixture-" + value + ".md")).write_text("# Plain note\n" + body)
        (memory / "knowledge" / "heading.md").write_text("# fixture topic " + value + "\n" + body)
        (memory / "decisions" / "fixture.md").write_text(
            "# fixture topic " + value + "\nDate: 2026-10-12\nStatus: accepted\n"
            "## Decision\n- " + body)
        (memory / "projects" / "fixture" / "overview.md").write_text(
            "# Fixture\n## Goal\n" + body + "## Constraints\n- Files first\n")
        (memory / "projects" / "fixture" / "log.md").write_text(
            "## 2026-10-12 10:00 — fixture\nStatus: " + value + "\nNext:\n- Fixture next\n")
        return memory

    def test_readers_sanitize_bodies_titles_paths_and_status(self):
        value = "sk-proj-" + "q" * 40
        memory = self.make_reader_fixture(value)
        for script in READERS:
            with self.subTest(reader=script):
                args = ["fixture"] if "project-status" in script else ["fixture topic value"]
                if "context-bootstrap" in script:
                    args += ["--project", "fixture"]
                result = self.run_script(script, args, memory)
                self.assertEqual(result.returncode, 0)
                self.assert_absent(value, result.stdout + result.stderr, script)

    def test_source_scanning_precedes_excerpt_truncation(self):
        value = "sk-proj-" + "q" * 240
        payload = "fixture private key payload " + "v" * 300
        memory = self.make_reader_fixture(value[:80], payload)
        # Match an interior key line without a recognizable token prefix.
        result = self.run_script(READERS[0], ["fixture private key payload", "--scopes", "knowledge"], memory)
        self.assertEqual(result.returncode, 0)
        self.assert_absent("v" * 30, result.stdout + result.stderr, "private key interior excerpt")
        (memory / "knowledge" / "long.md").write_text("# Plain\nfixture long value " + value + "\n")
        result = self.run_script(READERS[0], ["fixture long value", "--scopes", "knowledge"], memory)
        self.assertEqual(result.returncode, 0)
        self.assert_absent("q" * 30, result.stdout + result.stderr, "token before truncation")

    def test_runtime_failure_withholds_reader_and_writer_data(self):
        value = "sk-proj-" + "q" * 40
        memory = self.make_reader_fixture(value)
        bin_dir = self.root / "broken-python"
        bin_dir.mkdir()
        shim = bin_dir / "python3"
        shim.write_text("#!/bin/bash\nexit 1\n")
        shim.chmod(0o755)
        env = {"PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", "")}
        for script in READERS:
            args = ["fixture"]
            result = self.run_script(script, args, memory, env)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assert_absent(value, result.stdout + result.stderr, "failed reader runtime")
        result = self.run_script("skills/memory-write/scripts/write.sh",
                                 ["--type", "knowledge", "--title", "Runtime failure", "--body", value],
                                 self.root / "failed-writer", env)
        self.assertNotEqual(result.returncode, 0)
        self.assert_absent(value, result.stdout + result.stderr, "failed writer runtime")
        self.assertFalse(any((self.root / "failed-writer" / "knowledge").glob("*.md")))


if __name__ == "__main__":
    unittest.main()
