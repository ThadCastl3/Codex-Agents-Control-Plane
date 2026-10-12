"""Disposable setup fixtures exercise diagnostics without reading live state."""

import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lib"))
from validate_setup import OWNED_AGENTS, OWNED_SKILLS, SetupValidator, yaml_mapping


class SetupValidationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="codex-setup-validation-")
        self.addCleanup(self.fixture.cleanup)
        base = Path(self.fixture.name)
        self.repo = base / "repo"
        self.memory = self.repo / "memory"
        self.codex = base / "codex"
        self.agents = base / "agents"
        self.codex.mkdir()
        self.agents.mkdir()
        (self.repo / "config/agents").mkdir(parents=True)
        (self.repo / "AGENTS.md").write_text("# Fixture instructions\n")
        for name, entrypoint in OWNED_SKILLS.items():
            skill = self.repo / "skills" / name
            (skill / "scripts").mkdir(parents=True)
            (skill / "agents").mkdir()
            (skill / "SKILL.md").write_text(f"---\nname: {name}\ndescription: Inspect the fixture workflow.\n---\n\n# Fixture skill\n")
            (skill / "agents/openai.yaml").write_text(
                'interface:\n  display_name: "Fixture workflow"\n  short_description: "Inspect fixture state"\n'
                'policy:\n  allow_implicit_invocation: true\n')
            script = skill / "scripts" / entrypoint
            script.write_text("#!/usr/bin/env bash\nexit 0\n")
            script.chmod(0o755)
        desired = {"schema_version": 1, "required_features": {"hooks": True}, "deprecated_feature_keys": ["js_repl"]}
        (self.repo / "config/desired-state.json").write_text(json.dumps(desired))
        hooks = {"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [
            {"type": "command", "command": "python3 fixture.py", "timeout": 5, "additionalContextLimit": 500}]}]}}
        (self.repo / "config/hooks.json").write_text(json.dumps(hooks))
        (self.repo / "config/project-map.json").write_text(json.dumps([{"root": "$HOME/fixture", "project": "fixture"}]))
        (self.repo / "hooks").mkdir()
        (self.repo / "hooks/control_plane.py").write_text("# Fixture hook adapter\n")
        for filename, name in OWNED_AGENTS.items():
            path = self.repo / "config/agents" / filename
            path.write_text(f'name = "{name}"\ndescription = "Inspect fixtures"\ndeveloper_instructions = "Use disposable fixtures."\nsandbox_mode = "read-only"\n')
            (self.codex / "agents").mkdir(exist_ok=True)
            (self.codex / "agents" / filename).symlink_to(path)
        (self.codex / "AGENTS.md").symlink_to(self.repo / "AGENTS.md")
        (self.codex / "skills").symlink_to(self.repo / "skills", target_is_directory=True)
        (self.agents / "skills").symlink_to(self.repo / "skills", target_is_directory=True)
        (self.codex / "hooks.json").symlink_to(self.repo / "config/hooks.json")
        (self.codex / "control-plane-hook.py").symlink_to(self.repo / "hooks/control_plane.py")
        (self.codex / "config.toml").write_text('[features]\nhooks = true\n\n[mcp_servers.context7]\nurl = "https://fixture.invalid/mcp"\n')
        (self.memory / "knowledge").mkdir(parents=True)
        (self.memory / "knowledge/reference.md").write_text("# Fixture reference\n")
        (self.memory / "index.md").write_text("# Fixture index\n\n## Projects\n\n## Patterns\n\n## Knowledge\n\n- [Fixture](knowledge/reference.md)\n")

    def checks(self):
        report = SetupValidator(self.repo, self.memory, self.codex, self.agents).run()
        return {item["id"]: item for item in report["checks"]}

    def test_valid_owned_setup_has_no_failures_and_reports_uncertain_runtime(self):
        checks = self.checks()
        self.assertFalse([item for item in checks.values() if item["status"] == "FAIL"])
        self.assertEqual(checks["hooks.trust"]["status"], "WARN")
        self.assertEqual(checks["vendor.manifest"]["status"], "WARN")
        self.assertEqual(checks["dependency.context7"]["status"], "PASS")
        self.assertIn("cannot establish whether it is callable", checks["dependency.context7"]["message"])

    def test_bad_frontmatter_and_missing_skill_metadata_fail(self):
        skill = self.repo / "skills/memory-write"
        (skill / "SKILL.md").write_text("---\nname: another-skill\ndescription: false\n---\n# Fixture\n")
        (skill / "agents/openai.yaml").unlink()
        checks = self.checks()
        self.assertEqual(checks["skill.memory-write.frontmatter"]["status"], "FAIL")
        self.assertEqual(checks["skill.memory-write.metadata"]["status"], "FAIL")

    def test_invalid_invocation_policy_fails(self):
        path = self.repo / "skills/secret-scan/agents/openai.yaml"
        path.write_text('interface:\n  display_name: "Scanner"\n  short_description: "Scan fixtures"\npolicy:\n  allow_implicit_invocation: "false"\n')
        self.assertEqual(self.checks()["skill.secret-scan.metadata"]["status"], "FAIL")

    def test_block_scalars_and_optional_dependency_sequences(self):
        values = yaml_mapping('description: >-\n  First fixture line\n  second fixture line.\nname: fixture\n')
        self.assertEqual(values["description"], "First fixture line second fixture line.")
        values = yaml_mapping('interface:\n  display_name: "Fixture"\n  short_description: "Inspect fixture"\ndependencies:\n  tools:\n    - type: mcp\n      value: first\n      description: First dependency\n    - type: mcp\n      value: second\n      description: Second dependency\npolicy:\n  allow_implicit_invocation: false\n')
        self.assertFalse(values["policy"]["allow_implicit_invocation"])

    def test_missing_and_escaping_markdown_references_fail(self):
        document = self.repo / "skills/memory-retrieve/SKILL.md"
        with document.open("a") as stream:
            stream.write("\n[Missing](references/missing.md)\n[Escaping](../../../outside.md)\n")
        (Path(self.fixture.name) / "outside.md").write_text("# Outside fixture\n")
        check = self.checks()["skill.memory-retrieve.references"]
        self.assertEqual(check["status"], "FAIL")
        self.assertIn("2 missing", check["message"])

    def test_markdown_examples_do_not_create_false_missing_references(self):
        document = self.repo / "skills/memory-retrieve/SKILL.md"
        with document.open("a") as stream:
            stream.write('\n```markdown\n[Example](missing-example.md)\n```\n`[Inline example](missing-inline.md)`\n[Web](https://fixture.invalid/docs)\n')
        self.assertEqual(self.checks()["skill.memory-retrieve.references"]["status"], "PASS")

    def test_dangling_index_and_symlink_escape_fail_without_memory_text(self):
        outside = Path(self.fixture.name) / "outside.md"
        outside.write_text("Private fixture content that must not be printed.\n")
        (self.memory / "knowledge/escape.md").symlink_to(outside)
        with (self.memory / "index.md").open("a") as stream:
            stream.write("- [Missing](knowledge/missing.md)\n- [Escape](knowledge/escape.md)\n")
        checks = self.checks()
        self.assertEqual(checks["index.targets"]["status"], "FAIL")
        self.assertIn("2 index targets", checks["index.targets"]["message"])
        self.assertNotIn("Private fixture content", json.dumps(checks))

    def test_chronological_logs_cannot_be_indexed(self):
        (self.memory / "logs").mkdir()
        (self.memory / "logs/fixture.md").write_text("# Fixture log\n")
        with (self.memory / "index.md").open("a") as stream:
            stream.write("\n## Logs\n- [Log](logs/fixture.md)\n")
        checks = self.checks()
        self.assertEqual(checks["index.no-logs"]["status"], "FAIL")
        self.assertEqual(checks["index.targets"]["status"], "PASS")

    def test_canonical_symlink_drift_and_dangling_legacy_link_fail(self):
        canonical = self.agents / "skills"
        canonical.unlink()
        canonical.mkdir()
        legacy = self.codex / "skills"
        legacy.unlink()
        legacy.symlink_to(Path(self.fixture.name) / "missing")
        checks = self.checks()
        self.assertEqual(checks["symlink.skills-canonical"]["status"], "FAIL")
        self.assertEqual(checks["symlink.skills-legacy"]["status"], "FAIL")

    def test_hook_and_agent_schema_failures_are_structured(self):
        path = self.repo / "config/hooks.json"
        values = json.loads(path.read_text())
        values["hooks"]["SessionStart"][0]["hooks"][0]["timeout"] = True
        path.write_text(json.dumps(values))
        agent = self.repo / "config/agents/memory-retriever.toml"
        agent.write_text('name = "memory_retriever"\ndescription = "Fixture"\ndeveloper_instructions = false\n')
        checks = self.checks()
        self.assertEqual(checks["config.hooks"]["status"], "FAIL")
        self.assertEqual(checks["agent.memory_retriever"]["status"], "FAIL")

    def test_config_is_read_only_and_credentials_are_never_reported(self):
        path = self.codex / "config.toml"
        sensitive = "sk-" + "x" * 24
        text = '[features]\nhooks = true\njs_repl = false\nunknown_app_feature = true\n\n[mcp_servers.context7]\nurl = "https://fixture.invalid/mcp"\n[mcp_servers.context7.http_headers]\nAuthorization = "Bearer ' + sensitive + '"\n'
        path.write_text(text)
        checks = self.checks()
        self.assertEqual(checks["runtime.retired-feature"]["status"], "WARN")
        self.assertEqual(checks["runtime.owned-features"]["status"], "PASS")
        self.assertNotIn(sensitive, json.dumps(checks))
        self.assertEqual(path.read_text(), text)

    def test_optional_ripgrep_warning(self):
        import shutil
        actual = shutil.which
        with patch("validate_setup.shutil.which", side_effect=lambda name: None if name == "rg" else actual(name)):
            self.assertEqual(self.checks()["dependency.rg"]["status"], "WARN")

    def test_vendor_checksum_drift_warns_without_modifying_snapshot(self):
        relative = "vendor/fixture.md"
        target = self.repo / relative
        target.parent.mkdir()
        target.write_text("Installed fixture snapshot\n")
        manifest = {"schema_version": 1, "cli_version": "0.159.2",
                    "provenance": "Installed snapshot; upstream revision unknown",
                    "files": {relative: hashlib.sha256(target.read_bytes()).hexdigest()}}
        (self.repo / "config/vendor-manifest.json").write_text(json.dumps(manifest))
        self.assertEqual(self.checks()["vendor.checksums"]["status"], "PASS")
        target.write_text("Updated fixture snapshot\n")
        checks = self.checks()
        self.assertEqual(checks["vendor.checksums"]["status"], "WARN")
        self.assertEqual(target.read_text(), "Updated fixture snapshot\n")

    def test_zero_context_limit_is_valid_and_missing_launcher_fails(self):
        path = self.repo / "config/hooks.json"
        values = json.loads(path.read_text())
        values["hooks"]["SessionStart"][0]["hooks"][0]["additionalContextLimit"] = 0
        path.write_text(json.dumps(values))
        self.assertEqual(self.checks()["config.hooks"]["status"], "PASS")
        (self.codex / "control-plane-hook.py").unlink()
        self.assertEqual(self.checks()["symlink.hook-launcher"]["status"], "FAIL")

    def test_cli_json_and_exit_status_on_failure(self):
        (self.memory / "knowledge/reference.md").unlink()
        result = subprocess.run([
            sys.executable, str(REPO_ROOT / "lib/validate_setup.py"), "--repo-root", str(self.repo),
            "--memory-root", str(self.memory), "--codex-home", str(self.codex), "--agents-home", str(self.agents),
        ], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertTrue(report["checks"])
        self.assertFalse(result.stderr)
        self.assertTrue(all(set(item) == {"id", "status", "message"} for item in report["checks"]))
        self.assertTrue(all(item["status"] in ("PASS", "WARN", "FAIL") for item in report["checks"]))


if __name__ == "__main__":
    unittest.main()
