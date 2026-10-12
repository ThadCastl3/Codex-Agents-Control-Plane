"""Disposable memory fixtures for decision authority and project snapshots."""

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "decision_state", REPO_ROOT / "lib" / "decision_state.py"
)
decision_state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decision_state)


class MemoryFixture(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="codex-memory-context-")
        self.root = Path(self.workspace.name)
        for scope in ("decisions", "projects", "patterns", "knowledge", "logs"):
            (self.root / scope).mkdir()
        (self.root / "index.md").write_text(
            "# Memory\n\n## Projects\n\n## Patterns\n\n## Knowledge\n", encoding="utf-8"
        )

    def tearDown(self):
        self.workspace.cleanup()

    def decision(self, name, status="accepted", supersedes="", text="Use current policy."):
        filename = self.root / "decisions" / name
        filename.parent.mkdir(parents=True, exist_ok=True)
        filename.write_text(
            f"# {filename.stem}\n\nDate: 2026-10-01\nStatus: {status}\n"
            + (f"Supersedes: {supersedes}\n" if supersedes else "")
            + f"\n## Context\n- Policy background.\n\n## Decision\n- {text}\n",
            encoding="utf-8",
        )
        return filename

    def run_skill(self, skill, *arguments):
        scripts = {
            "decision-check": "check.sh",
            "memory-retrieve": "retrieve.sh",
            "project-status": "status.sh",
            "context-bootstrap": "bootstrap.sh",
        }
        return subprocess.run(
            ["bash", str(REPO_ROOT / "skills" / skill / "scripts" / scripts[skill]), *arguments],
            env={**os.environ, "MEMORY_ROOT": str(self.root)},
            text=True,
            capture_output=True,
            timeout=60,
        )

    def graph(self):
        return decision_state.resolve_decisions(self.root)

    def project(self, log):
        directory = self.root / "projects" / "launch"
        directory.mkdir()
        (directory / "overview.md").write_text(
            "# Launch\n\n## Goal\n- Ship the launch.\n\n## Constraints\n- Use disposable fixtures.\n",
            encoding="utf-8",
        )
        (directory / "log.md").write_text(log, encoding="utf-8")

    @staticmethod
    def section(output, name):
        return output.split(f"**{name}:**", 1)[1].split("\n**", 1)[0]


class DecisionGraphTests(MemoryFixture):
    def test_reference_forms_resolve_before_query_ranking(self):
        self.decision("old.md")
        for reference in ("old", "old.md", "decisions/old.md", "memory/decisions/old.md"):
            with self.subTest(reference=reference):
                self.decision("new.md", supersedes=reference)
                graph = self.graph()
                self.assertEqual([], graph["diagnostics"])
                self.assertEqual("superseded", graph["decisions"]["decisions/old.md"]["state"])
                self.assertEqual("active", graph["decisions"]["decisions/new.md"]["state"])

    def test_chain_follows_terminal_accepted_replacement(self):
        self.decision("old.md")
        self.decision("middle.md", supersedes="old")
        self.decision("new.md", supersedes="middle")
        graph = self.graph()
        self.assertEqual(["decisions/new.md"], graph["decisions"]["decisions/old.md"]["replacements"])
        self.assertEqual("superseded", graph["decisions"]["decisions/middle.md"]["state"])

    def test_advisory_replacement_cannot_supersede_accepted(self):
        self.decision("old.md")
        for status in ("proposed", "deprecated"):
            with self.subTest(status=status):
                self.decision("new.md", status=status, supersedes="old")
                graph = self.graph()
                self.assertEqual("active", graph["decisions"]["decisions/old.md"]["state"])
                self.assertEqual("advisory", graph["decisions"]["decisions/new.md"]["state"])

    def test_cycles_have_explicit_diagnostic_and_no_binding_nodes(self):
        self.decision("first.md", supersedes="second")
        self.decision("second.md", supersedes="first")
        graph = self.graph()
        self.assertTrue(any("cycle" in item for item in graph["diagnostics"]))
        self.assertEqual({"unresolved"}, {item["state"] for item in graph["decisions"].values()})

    def test_missing_accepted_reference_is_unresolved(self):
        self.decision("new.md", supersedes="missing.md")
        graph = self.graph()
        self.assertIn("missing supersedes target", graph["diagnostics"][0])
        self.assertEqual("unresolved", graph["decisions"]["decisions/new.md"]["state"])

    def test_competing_replacements_do_not_choose_newest(self):
        self.decision("old.md")
        self.decision("left.md", supersedes="old")
        self.decision("right.md", supersedes="old")
        graph = self.graph()
        self.assertTrue(any("competing effective replacements" in item for item in graph["diagnostics"]))
        self.assertEqual({"unresolved"}, {item["state"] for item in graph["decisions"].values()})

    def test_merge_replacement_resolves_a_previous_branch(self):
        self.decision("old.md")
        self.decision("left.md", supersedes="old")
        self.decision("right.md", supersedes="old")
        self.decision("merged.md", supersedes="left, right")
        graph = self.graph()
        self.assertEqual([], graph["diagnostics"])
        self.assertEqual("active", graph["decisions"]["decisions/merged.md"]["state"])
        self.assertEqual(["decisions/merged.md"], graph["decisions"]["decisions/old.md"]["replacements"])

    def test_ambiguous_basename_is_diagnostic_but_full_path_resolves(self):
        self.decision("one/old.md")
        self.decision("two/old.md")
        self.decision("new.md", supersedes="old")
        self.assertTrue(any("ambiguous" in item for item in self.graph()["diagnostics"]))
        self.decision("new.md", supersedes="decisions/one/old.md")
        graph = self.graph()
        self.assertEqual([], graph["diagnostics"])
        self.assertEqual("active", graph["decisions"]["decisions/two/old.md"]["state"])

    def test_missing_status_is_advisory(self):
        filename = self.decision("legacy.md")
        filename.write_text(filename.read_text().replace("Status: accepted\n", ""), encoding="utf-8")
        self.assertEqual("advisory", self.graph()["decisions"]["decisions/legacy.md"]["state"])


class DecisionReaderTests(MemoryFixture):
    def test_old_query_returns_only_current_accepted_constraints(self):
        self.decision("legacytransport.md", text="legacytransport must use obsolete transport.")
        self.decision("replacement.md", supersedes="legacytransport", text="Must use current transport.")
        result = self.run_skill("decision-check", "legacytransport")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("CONSTRAINT: Must use current transport.", result.stdout)
        self.assertNotIn("obsolete transport", result.stdout)
        retrieved = self.run_skill("memory-retrieve", "legacytransport", "--scopes", "decisions", "--explain")
        self.assertEqual(0, retrieved.returncode, retrieved.stderr)
        self.assertIn("decisions/replacement.md", retrieved.stdout)
        self.assertNotIn("decisions/legacytransport.md", retrieved.stdout)
        self.assertIn("supersede=0", retrieved.stdout)

    def test_proposed_and_deprecated_records_never_emit_constraint_markers(self):
        self.decision("proposalpolicy.md", status="proposed", text="proposalpolicy should change.")
        self.decision("retiredpolicy.md", status="deprecated", text="retiredpolicy should return.")
        for query in ("proposalpolicy", "retiredpolicy"):
            with self.subTest(query=query):
                result = self.run_skill("decision-check", query)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn("advisory", result.stdout)
                self.assertNotIn("CONSTRAINT:", result.stdout)
                retrieved = self.run_skill("memory-retrieve", query, "--scopes", "decisions")
                self.assertEqual(0, retrieved.returncode, retrieved.stderr)
                self.assertIn("advisory decision record (not binding)", retrieved.stdout)
                self.assertNotIn("Authoritative", retrieved.stdout)

    def test_proposal_supersession_retains_existing_constraint(self):
        self.decision("routingpolicy.md", text="routingpolicy must retain accepted behavior.")
        self.decision("proposal.md", status="proposed", supersedes="routingpolicy", text="routingpolicy should change.")
        result = self.run_skill("decision-check", "routingpolicy")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("CONSTRAINT: routingpolicy must retain accepted behavior.", result.stdout)
        self.assertNotIn("CONSTRAINT: routingpolicy should change.", result.stdout)

    def test_bootstrap_keeps_advisory_records_out_of_binding_constraints(self):
        self.decision("proposalpolicy.md", status="proposed", text="proposalpolicy should change.")
        result = self.run_skill("context-bootstrap", "proposalpolicy")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("No accepted decision constraints apply; related records are advisory.", result.stdout)
        self.assertNotIn("proposalpolicy should change", result.stdout)
        self.assertNotIn("No relevant decision found.", result.stdout)

    def test_graph_failure_remains_unavailable_in_bootstrap(self):
        self.decision("routingpolicy.md", supersedes="missing")
        result = self.run_skill("decision-check", "routingpolicy")
        self.assertEqual(3, result.returncode)
        self.assertIn("missing supersedes target", result.stdout)
        self.assertNotIn("CONSTRAINT:", result.stdout)
        bootstrap = self.run_skill("context-bootstrap", "routingpolicy")
        self.assertEqual(0, bootstrap.returncode, bootstrap.stderr)
        self.assertIn("Decision context unavailable", bootstrap.stdout)
        self.assertIn("skill=decision-check exit_code=3 failed", bootstrap.stdout)
        self.assertNotIn("No relevant decision found.", bootstrap.stdout)

    def test_missing_source_distinguished_from_empty_decisions(self):
        empty = self.run_skill("context-bootstrap", "routingpolicy")
        self.assertEqual(0, empty.returncode, empty.stderr)
        self.assertIn("No relevant decision found.", empty.stdout)
        (self.root / "decisions").rmdir()
        unavailable = self.run_skill("context-bootstrap", "routingpolicy")
        self.assertEqual(0, unavailable.returncode, unavailable.stderr)
        self.assertIn("Decision context unavailable", unavailable.stdout)
        self.assertNotIn("No relevant decision found.", unavailable.stdout)


class ProjectSnapshotTests(MemoryFixture):
    def test_explicit_none_clears_old_next_actions_and_blockers(self):
        self.project(
            "## 2026-10-01\nStatus: Working\nNext:\n- [ ] Old task\nBlockers:\n- Old blocker\n\n"
            "## 2026-10-02\nStatus: Complete\nNext: None\nBlockers: None\n"
        )
        result = self.run_skill("project-status", "launch")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("**Current Status:** Complete", result.stdout)
        self.assertIn("(None.)", self.section(result.stdout, "Next Actions"))
        self.assertIn("(None.)", self.section(result.stdout, "Blockers / Risks"))
        self.assertNotIn("Old task", self.section(result.stdout, "Next Actions"))
        self.assertNotIn("Old blocker", self.section(result.stdout, "Blockers / Risks"))

    def test_latest_fields_are_independent_and_completed_tasks_are_excluded(self):
        self.project(
            "## 2026-10-01\nStatus: Working\nNext:\n- [ ] Stale task\nBlockers:\n- Current blocker\n\n"
            "## 2026-10-02\nNext:\n- [x] Completed task\n- [ ] Current task\n\n"
            "## 2026-10-03\nNotes:\n- New information\n"
        )
        result = self.run_skill("project-status", "launch", "--since", "2026-10-03", "--max-updates", "1")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("**Current Status:** Working", result.stdout)
        actions = self.section(result.stdout, "Next Actions")
        self.assertIn("Current task", actions)
        self.assertNotIn("Completed task", actions)
        self.assertNotIn("Stale task", actions)
        self.assertIn("Current blocker", self.section(result.stdout, "Blockers / Risks"))

    def test_empty_snapshot_clears_previous_values(self):
        self.project(
            "## 2026-10-01\nStatus: Working\nNext: Old task\nBlockers: Old blocker\n\n"
            "## 2026-10-02\nStatus: Complete\nNext:\nBlockers:\n"
        )
        result = self.run_skill("project-status", "launch")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("(None.)", self.section(result.stdout, "Next Actions"))
        self.assertIn("(None.)", self.section(result.stdout, "Blockers / Risks"))


if __name__ == "__main__":
    unittest.main()
