import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "lib"))
from control_plane_setup import Installer, config_text
from memory_transaction import LOCK_NAME


class SetupHooksSnapshots(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.memory = self.root / "memory"
        self.memory.mkdir()
        self.state = self.root / "runtime"
        self.snapshots = self.root / "snapshots"
        for name in ["decisions", "projects", "knowledge", "patterns", "logs"]:
            (self.memory / name).mkdir()
        (self.memory / "index.md").write_text("# Index\n\n## Projects\n\n## Patterns\n\n## Knowledge\n")

    def tearDown(self):
        self.temp.cleanup()

    def hook(self, event):
        env = dict(os.environ, MEMORY_ROOT=str(self.memory), CODEX_CONTROL_PLANE_RUNTIME=str(self.state))
        result = subprocess.run([sys.executable, str(REPO / "hooks/control_plane.py")], input=json.dumps(event), text=True, capture_output=True, env=env, timeout=25)
        self.assertEqual(result.returncode, 0)
        return json.loads(result.stdout)

    def event(self, name, **fields):
        return dict(hook_event_name=name, session_id="session", turn_id="turn", cwd=str(self.root), **fields)

    def test_context_dedup_and_compaction(self):
        first = self.hook(self.event("UserPromptSubmit", prompt="Review the project architecture"))
        self.assertIn("Bootstrap completed", first["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.hook(self.event("UserPromptSubmit", prompt="Review the project architecture")), {})
        compact = self.hook(self.event("SessionStart", source="compact"))
        self.assertIn("Context", compact["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.hook(self.event("SessionStart", source="compact")), {})

    def test_subagent_and_prompt_privacy(self):
        value = "sk-proj-" + "q" * 32
        result = self.hook(self.event("UserPromptSubmit", prompt="Review project " + value))
        self.assertNotIn(value, json.dumps(result))
        for path in self.state.rglob("*.json"):
            self.assertNotIn(value, path.read_text())
            self.assertNotIn("Review project", path.read_text())
        child = self.hook(self.event("SubagentStart", agent_id="child", agent_type="worker"))
        self.assertIn("ownership", child["hookSpecificOutput"]["additionalContext"])

    def test_patch_guard_add_update_delete_move_and_unrelated(self):
        for operation in ["Add", "Update", "Delete"]:
            patch = f"*** Begin Patch\n*** {operation} File: {self.memory}/decisions/a.md\n*** End Patch"
            result = self.hook(self.event("PreToolUse", tool_name="apply_patch", tool_input={"command": patch}))
            self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")
        moved = f"*** Update File: source.md\n*** Move to: {self.memory}/projects/new/log.md\n"
        self.assertEqual(self.hook(self.event("PreToolUse", tool_name="apply_patch", tool_input={"command": moved}))["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(self.hook(self.event("PreToolUse", tool_name="apply_patch", tool_input={"command": "*** Update File: README.md\n"})), {})
        self.assertEqual(self.hook(self.event("PreToolUse", tool_name="Bash", tool_input={"command": "echo ok"})), {})
        linked = self.memory / "decisions/linked.md"
        linked.symlink_to(self.root / "outside.md")
        result = self.hook(self.event("PreToolUse", tool_name="apply_patch", tool_input={"command": f"*** Update File: {linked}\n"}))
        self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_recorded_stop_is_bounded(self):
        env = dict(os.environ, MEMORY_ROOT=str(self.memory), CODEX_CONTROL_PLANE_RUNTIME=str(self.state))
        command = [sys.executable, str(REPO / "hooks/control_plane.py"), "--record-check", "--session-id", "session", "--turn-id", "turn", "--", sys.executable, "-c", "raise SystemExit(1)"]
        self.assertEqual(subprocess.run(command, env=env, capture_output=True).returncode, 1)
        self.assertEqual(self.hook(self.event("Stop", stop_hook_active=False))["decision"], "block")
        self.assertEqual(self.hook(self.event("Stop", stop_hook_active=True)), {})
        command[-1] = "raise SystemExit(0)"
        self.assertEqual(subprocess.run(command, env=env, capture_output=True).returncode, 0)
        self.assertEqual(self.hook(self.event("Stop", stop_hook_active=False)), {})
        receipt = next((self.state / "checks").glob("*.json"))
        receipt.write_text("[]")
        self.assertIn("systemMessage", self.hook(self.event("Stop", stop_hook_active=False)))

    def test_invalid_hook_is_value_free(self):
        self.assertIn("systemMessage", self.hook(["invalid"]))
        self.assertIn("systemMessage", self.hook(self.event("UserPromptSubmit", prompt="review", tool_input=[], source={"bad": True})))

    def test_unavailable_decisions_require_manual_bootstrap(self):
        (self.memory / "decisions").rmdir()
        result = self.hook(self.event("UserPromptSubmit", prompt="Review architecture"))
        context = result["hookSpecificOutput"]["additionalContext"]
        self.assertNotIn("Bootstrap completed for this task.", context)
        self.assertIn("manual follow-up", context)

    def test_install_dry_run_and_idempotence(self):
        codex, agents = self.root / "codex", self.root / "agents"
        Installer(REPO, codex, agents, dry_run=True).install()
        self.assertFalse(codex.exists())
        Installer(REPO, codex, agents).install()
        self.assertEqual((agents / "skills").resolve(), REPO / "skills")
        self.assertEqual((codex / "AGENTS.md").resolve(), REPO / "AGENTS.md")
        self.assertEqual((codex / "hooks.json").resolve(), REPO / "config/hooks.json")
        actions = Installer(REPO, codex, agents).install()
        self.assertTrue(all(action["action"] == "already-linked" for action in actions))

    def test_foreign_hooks_preserved_before_install(self):
        codex = self.root / "codex"
        codex.mkdir()
        (codex / "hooks.json").write_text('{"hooks": {}}')
        with self.assertRaises(ValueError):
            Installer(REPO, codex, self.root / "agents").install()
        self.assertFalse((codex / "AGENTS.md").exists())
        self.assertEqual((codex / "hooks.json").read_text(), '{"hooks": {}}')

    def test_curated_config_keeps_machine_values(self):
        desired = json.loads((REPO / "config/desired-state.json").read_text())
        before = 'model = "current"\n[features]\njs_repl = false\nother = true\n[mcp_servers.test]\ncommand = "owned-by-app"\n'
        updated = config_text(before, desired)
        self.assertNotIn("js_repl", updated)
        self.assertIn("owned-by-app", updated)
        self.assertIn("other = true", updated)
        self.assertEqual(config_text(updated, desired), updated)
        array = before + '[[skills.config]]\npath = "/tmp/skill/SKILL.md"\nenabled = false\n'
        self.assertIn('[[skills.config]]', config_text(array, desired))

    def test_symlink_config_backup_preserves_original_bytes(self):
        codex = self.root / "codex"
        codex.mkdir()
        actual = self.root / "actual.toml"
        original = '[features]\njs_repl = false\n'
        actual.write_text(original)
        (codex / "config.toml").symlink_to(actual)
        source = self.root / "source"
        source.mkdir()
        for name in ["AGENTS.md", "skills", "config", "hooks"]:
            (source / name).symlink_to(REPO / name)
        installer = Installer(source, codex, self.root / "agents")
        actions = installer.install()
        backup = next(item["backup"] for item in actions if item["action"] == "backup" and item["target"].endswith("config.toml"))
        self.assertFalse(Path(backup).is_symlink())
        self.assertEqual(Path(backup).read_text(), original)

    def snapshot(self, action, name=None):
        args = [sys.executable, str(REPO / "bin/memory-snapshot.py"), action]
        if name:
            args.append(name)
        args += ["--memory-root", str(self.memory), "--snapshot-root", str(self.snapshots)]
        return subprocess.run(args, capture_output=True, text=True, timeout=10)

    def test_restore_includes_index_and_preserves_lock_inode(self):
        note = self.memory / "knowledge/note.md"
        note.write_text("# Original\nSafe content\n")
        original_index = (self.memory / "index.md").read_text() + "- [Note](knowledge/note.md)\n"
        (self.memory / "index.md").write_text(original_index)
        created = self.snapshot("create")
        self.assertEqual(created.returncode, 0)
        name = json.loads(created.stdout)["snapshot"]
        inode = (self.memory / LOCK_NAME).stat().st_ino
        note.write_text("# Changed\n")
        (self.memory / "knowledge/extra.md").write_text("# Extra\n")
        (self.memory / "index.md").write_text("# Changed index\n")
        restored = self.snapshot("restore", name)
        self.assertEqual(restored.returncode, 0)
        self.assertEqual(note.read_text(), "# Original\nSafe content\n")
        self.assertEqual((self.memory / "index.md").read_text(), original_index)
        self.assertFalse((self.memory / "knowledge/extra.md").exists())
        self.assertEqual((self.memory / LOCK_NAME).stat().st_ino, inode)

    def test_tampered_snapshot_and_symlinks_refused(self):
        (self.memory / "knowledge/note.md").write_text("# Safe\n")
        name = json.loads(self.snapshot("create").stdout)["snapshot"]
        (self.snapshots / name / "files/knowledge/note.md").write_text("# Tampered\n")
        self.assertEqual(self.snapshot("restore", name).returncode, 2)
        self.assertEqual((self.memory / "knowledge/note.md").read_text(), "# Safe\n")
        (self.memory / "knowledge/linked.md").symlink_to(self.root / "outside.md")
        self.assertEqual(self.snapshot("create").returncode, 2)

    def test_hidden_documents_excluded_and_invalid_manifest_refused(self):
        (self.memory / ".hidden.md").write_text("# Hidden\n")
        name = json.loads(self.snapshot("create").stdout)["snapshot"]
        self.assertEqual(self.snapshot("restore", name).returncode, 0)
        (self.snapshots / name / "manifest.json").write_text("[]")
        result = self.snapshot("restore", name)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
