"""Read private memory independently of Git visibility and root spelling."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPTS = {
    "decision-check": "check.sh",
    "memory-retrieve": "retrieve.sh",
    "context-bootstrap": "bootstrap.sh",
}


class MemoryPathTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="codex-memory-paths-")
        self.addCleanup(self.fixture.cleanup)
        self.workspace = Path(self.fixture.name)
        self.memory = self.workspace / "memory"
        for scope in ("decisions", "projects", "patterns", "knowledge", "logs"):
            (self.memory / scope).mkdir(parents=True)
        (self.memory / "index.md").write_text("# Memory\n", encoding="utf-8")

    def private_git_memory(self):
        subprocess.run(["git", "init", "-q", str(self.workspace)], check=True)
        (self.workspace / ".gitignore").write_text(
            "memory/**\n!memory/**/\n!memory/index.md\n", encoding="utf-8"
        )

    def without_ripgrep(self):
        """Exercise the portable fallback without depending on the host PATH."""
        directory = self.workspace / "no-rg-bin"
        directory.mkdir(exist_ok=True)
        commands = (
            "awk", "basename", "cat", "cut", "date", "dirname", "find",
            "grep", "head", "mktemp", "paste", "rm", "sed", "sort",
            "stat", "tr", "wc",
        )
        for name in commands:
            executable = shutil.which(name)
            self.assertIsNotNone(executable, name)
            (directory / name).symlink_to(executable)
        (directory / "python3").symlink_to(sys.executable)
        return {"PATH": str(directory)}

    def decision(self, name="storage.md", supersedes="", text="Must use ambertransport."):
        path = self.memory / "decisions" / name
        path.write_text(
            "# Storage policy\nDate: 2026-10-12\nStatus: accepted\n"
            + (f"Supersedes: {supersedes}\n" if supersedes else "")
            + f"\n## Decision\n- {text}\n",
            encoding="utf-8",
        )
        return path

    def invoke_reader(self, skill, *args, root=None, extra_env=None):
        env = dict(os.environ, MEMORY_ROOT=str(root or self.memory))
        env.update(extra_env or {})
        return subprocess.run(
            ["/bin/bash", str(REPO / "skills" / skill / "scripts" / SCRIPTS[skill]), *args],
            cwd=self.workspace, env=env, text=True, capture_output=True, timeout=30,
        )

    def run_reader(self, skill, *args, root=None, extra_env=None):
        result = self.invoke_reader(skill, *args, root=root, extra_env=extra_env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "", result.stderr)
        return result.stdout

    def test_ignored_body_match_remains_a_binding_decision(self):
        self.private_git_memory()
        path = self.decision()
        ignored = subprocess.run(
            ["git", "check-ignore", "-q", str(path)], cwd=self.workspace,
        )
        self.assertEqual(ignored.returncode, 0)
        output = self.run_reader("decision-check", "ambertransport")
        self.assertIn("CONSTRAINT: Must use ambertransport.", output)
        self.assertNotIn("No relevant decision found.", output)
        output = self.run_reader("memory-retrieve", "ambertransport", "--scopes", "decisions")
        self.assertIn("decisions/storage.md", output)
        self.assertNotIn("advisory", output)

    def test_ignored_knowledge_and_patterns_reach_retrieval_and_bootstrap(self):
        self.private_git_memory()
        self.decision()
        for scope in ("knowledge", "patterns"):
            (self.memory / scope / "transport.md").write_text(
                "# ambertransport reference\n\n## Steps\n- Use ambertransport.\n",
                encoding="utf-8",
            )
        output = self.run_reader("memory-retrieve", "ambertransport", "--scopes", "knowledge,patterns")
        self.assertIn("knowledge/transport.md", output)
        self.assertIn("patterns/transport.md", output)
        output = self.run_reader("context-bootstrap", "ambertransport")
        self.assertIn("- Must use ambertransport.", output)
        self.assertIn("knowledge/transport.md", output)
        self.assertIn("patterns/transport.md", output)
        self.assertNotIn("No relevant decision found.", output)

    def test_equivalent_roots_preserve_accepted_authority(self):
        self.decision()
        alias = self.workspace / "memory-alias"
        alias.symlink_to(self.memory, target_is_directory=True)
        for root in (str(self.memory), str(self.memory) + "/", "memory", "./memory/", "memory-alias/"):
            with self.subTest(root=root):
                output = self.run_reader("decision-check", "ambertransport", root=root)
                self.assertIn("CONSTRAINT: Must use ambertransport.", output)
                self.assertIn("`decisions/storage.md`", output)
                output = self.run_reader("memory-retrieve", "ambertransport", "--scopes", "decisions", root=root)
                self.assertIn("decisions/storage.md", output)
                self.assertNotIn("advisory", output)

    def test_equivalent_roots_follow_supersession_in_ignored_memory(self):
        self.private_git_memory()
        self.decision(text="Must use ambertransport legacy transport.")
        self.decision("replacement.md", "decisions/storage.md", "Must use current transport.")
        for root in (str(self.memory), str(self.memory) + "/", "memory"):
            with self.subTest(root=root):
                output = self.run_reader("decision-check", "ambertransport", root=root)
                self.assertIn("CONSTRAINT: Must use current transport.", output)
                self.assertNotIn("legacy transport", output)
                output = self.run_reader("memory-retrieve", "ambertransport", "--scopes", "decisions", root=root)
                self.assertIn("decisions/replacement.md", output)
                self.assertNotIn("decisions/storage.md", output)
                self.assertNotIn("advisory", output)
                output = self.run_reader("context-bootstrap", "ambertransport", root=root)
                self.assertIn("- Must use current transport.", output)

    def test_search_does_not_follow_memory_symlinks(self):
        self.private_git_memory()
        outside = self.workspace / "outside"
        outside.mkdir()
        target = outside / "external.md"
        target.write_text("# ambertransport external sentinel\n", encoding="utf-8")
        (self.memory / "knowledge" / "file.md").symlink_to(target)
        (self.memory / "knowledge" / "directory").symlink_to(outside, target_is_directory=True)
        (self.memory / "patterns").rmdir()
        (self.memory / "patterns").symlink_to(outside, target_is_directory=True)
        (self.memory / "knowledge" / "ignored.txt").write_text(
            "# ambertransport non-Markdown sentinel\n", encoding="utf-8"
        )
        for extra_env in ({}, self.without_ripgrep()):
            with self.subTest(fallback=bool(extra_env)):
                output = self.run_reader(
                    "memory-retrieve", "ambertransport", "--scopes", "knowledge,patterns",
                    extra_env=extra_env,
                )
                self.assertNotIn("external sentinel", output)
                self.assertNotIn("non-Markdown sentinel", output)
                self.assertIn("No relevant entries found", output)

    def test_grep_fallback_reads_ignored_markdown(self):
        self.private_git_memory()
        self.decision()
        (self.memory / "knowledge" / "transport.md").write_text(
            "# ambertransport reference\n", encoding="utf-8"
        )
        extra_env = self.without_ripgrep()
        output = self.run_reader("decision-check", "ambertransport", extra_env=extra_env)
        self.assertIn("CONSTRAINT: Must use ambertransport.", output)
        output = self.run_reader(
            "memory-retrieve", "ambertransport", "--scopes", "decisions,knowledge",
            extra_env=extra_env,
        )
        self.assertIn("decisions/storage.md", output)
        self.assertIn("knowledge/transport.md", output)
        self.assertNotIn("advisory", output)

    def test_symlinked_replacement_makes_decision_context_unavailable(self):
        self.private_git_memory()
        self.decision()
        external = self.workspace / "external-policy.md"
        external.write_text(
            "# External policy\nStatus: accepted\nSupersedes: decisions/storage.md\n"
            "\n## Decision\n- External policy sentinel must not be read.\n",
            encoding="utf-8",
        )
        (self.memory / "decisions" / "replacement.md").symlink_to(external)
        for skill, args in (
            ("decision-check", ("ambertransport",)),
            ("memory-retrieve", ("ambertransport", "--scopes", "decisions")),
        ):
            with self.subTest(reader=skill):
                result = self.invoke_reader(skill, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Decision context unavailable", result.stdout)
                self.assertNotIn("External policy sentinel", result.stdout + result.stderr)
                self.assertNotIn("No relevant decision found", result.stdout)
        output = self.run_reader("context-bootstrap", "ambertransport")
        self.assertIn("Decision context unavailable", output)
        self.assertNotIn("No relevant decision found", output)
        self.assertNotIn("External policy sentinel", output)

    def test_linked_decision_subtree_is_unavailable(self):
        self.decision()
        external = self.workspace / "outside-decisions"
        external.mkdir()
        (external / "replacement.md").write_text(
            "# External policy\nStatus: accepted\nSupersedes: decisions/storage.md\n"
            "\n## Decision\n- External subtree sentinel must not be read.\n",
            encoding="utf-8",
        )
        (self.memory / "decisions" / "nested").symlink_to(external, target_is_directory=True)
        result = self.invoke_reader("decision-check", "ambertransport")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Decision context unavailable", result.stdout)
        self.assertNotIn("External subtree sentinel", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
