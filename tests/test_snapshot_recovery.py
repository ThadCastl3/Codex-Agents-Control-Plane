import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("snapshot_recovery", REPO / "bin/memory-snapshot.py")
snapshot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(snapshot)


class SnapshotRecovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.memory = self.root / "memory"
        self.snapshots = self.root / "snapshots"
        self.memory.mkdir()
        (self.memory / "index.md").write_text("# Snapshot index\n")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, relative, content):
        path = self.memory / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def capture(self):
        with snapshot.memory_lock(self.memory):
            return snapshot.capture(self.memory, self.snapshots)[0]

    def restore(self, name):
        with snapshot.memory_lock(self.memory):
            return snapshot.restore(self.memory, self.snapshots, name)

    def test_symlink_rejection_preserves_external_file(self):
        note = self.write("knowledge/note.md", "# Saved note\n")
        name = self.capture()
        note.unlink()
        note.parent.rmdir()
        outside = self.root / "outside"
        outside.mkdir()
        external = outside / "note.md"
        external.write_text("# External content must survive\n")
        note.parent.symlink_to(outside, target_is_directory=True)

        with self.assertRaises(ValueError):
            self.restore(name)

        self.assertTrue(external.is_file(), "rejected restore deleted an external file")
        self.assertEqual(external.read_text(), "# External content must survive\n")
        self.assertEqual((self.memory / "index.md").read_text(), "# Snapshot index\n")

    def test_capture_rejects_visible_symlink_directory(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "note.md").write_text("# Linked document\n")
        (self.memory / "linked").symlink_to(outside, target_is_directory=True)

        with self.assertRaises(ValueError):
            self.capture()

        self.assertFalse(self.snapshots.exists())

    def test_preflight_rejects_parent_file_before_any_memory_write(self):
        note = self.write("knowledge/note.md", "# Saved note\n")
        name = self.capture()
        note.unlink()
        note.parent.rmdir()
        note.parent.write_text("This existing non-Markdown file must survive.\n")
        (self.memory / "index.md").write_text("# Current index\n")
        writes = []
        original_publish = snapshot.publish_file

        def record_publish(destination, data, **kwargs):
            if Path(destination).is_relative_to(self.memory):
                writes.append(Path(destination))
            return original_publish(destination, data, **kwargs)

        with mock.patch.object(snapshot, "publish_file", side_effect=record_publish):
            with self.assertRaises((ValueError, OSError)):
                self.restore(name)

        self.assertEqual(writes, [], "invalid destinations must be rejected before mutation")
        self.assertEqual((self.memory / "index.md").read_text(), "# Current index\n")
        self.assertEqual(note.parent.read_text(), "This existing non-Markdown file must survive.\n")

    def test_partial_write_failure_rolls_back_only_changed_documents(self):
        created = self.write("knowledge/created.md", "# Snapshot new document\n")
        failing = self.write("knowledge/failing.md", "# Snapshot later document\n")
        unchanged = self.write("knowledge/untouched.md", "# Snapshot old document\n")
        name = self.capture()
        created.unlink()
        failing.unlink()
        unchanged.write_text("# Current untouched document\n")
        (self.memory / "index.md").write_text("# Current index\n")
        original_inode = unchanged.stat().st_ino
        original_publish = snapshot.publish_file

        def fail_one_publish(destination, data, **kwargs):
            if Path(destination) == failing:
                raise OSError("injected write failure")
            return original_publish(destination, data, **kwargs)

        with mock.patch.object(snapshot, "publish_file", side_effect=fail_one_publish):
            with self.assertRaisesRegex(OSError, "injected write failure"):
                self.restore(name)

        self.assertEqual((self.memory / "index.md").read_text(), "# Current index\n")
        self.assertFalse(created.exists())
        self.assertFalse(failing.exists())
        self.assertEqual(unchanged.read_text(), "# Current untouched document\n")
        self.assertEqual(unchanged.stat().st_ino, original_inode, "rollback rewrote an untouched file")

    def test_rollback_rechecks_containment_after_partial_failure(self):
        created = self.write("knowledge/created.md", "# Snapshot new document\n")
        failing = self.write("later.md", "# Snapshot later document\n")
        name = self.capture()
        created.unlink()
        failing.unlink()
        outside = self.root / "outside"
        outside.mkdir()
        external = outside / "created.md"
        external.write_text("# External rollback sentinel\n")
        original_publish = snapshot.publish_file

        def replace_parent_then_fail(destination, data, **kwargs):
            if Path(destination) == failing:
                created.parent.rename(self.root / "moved-knowledge")
                created.parent.symlink_to(outside, target_is_directory=True)
                raise OSError("injected failure after parent changed")
            return original_publish(destination, data, **kwargs)

        with mock.patch.object(snapshot, "publish_file", side_effect=replace_parent_then_fail):
            with self.assertRaisesRegex(ValueError, "rollback was incomplete; recovery snapshot:"):
                self.restore(name)

        self.assertTrue(external.is_file(), "rollback followed a replaced parent symlink")
        self.assertEqual(external.read_text(), "# External rollback sentinel\n")
        self.assertTrue((self.root / "moved-knowledge/created.md").is_file())

    def test_partial_deletion_failure_restores_removed_documents(self):
        name = self.capture()
        first = self.write("knowledge/first.md", "# First current document\n")
        second = self.write("knowledge/second.md", "# Second current document\n")
        (self.memory / "index.md").write_text("# Current index\n")
        lock_inode = (self.memory / snapshot.LOCK_NAME).stat().st_ino
        original_unlink = Path.unlink
        removed = []

        def fail_second_removal(path, *args, **kwargs):
            if path == second:
                raise OSError("injected deletion failure")
            result = original_unlink(path, *args, **kwargs)
            if path == first:
                removed.append(path)
            return result

        with mock.patch.object(Path, "unlink", new=fail_second_removal):
            with self.assertRaisesRegex(OSError, "injected deletion failure"):
                self.restore(name)

        self.assertEqual(removed, [first])
        self.assertEqual(first.read_text(), "# First current document\n")
        self.assertEqual(second.read_text(), "# Second current document\n")
        self.assertEqual((self.memory / "index.md").read_text(), "# Current index\n")
        self.assertEqual((self.memory / snapshot.LOCK_NAME).stat().st_ino, lock_inode)

        recovery, count = self.restore(name)
        self.assertEqual(count, 1)
        self.assertFalse(first.exists())
        self.assertFalse(second.exists())
        self.restore(recovery)
        self.assertEqual(first.read_text(), "# First current document\n")
        self.assertEqual(second.read_text(), "# Second current document\n")
        self.assertEqual((self.memory / snapshot.LOCK_NAME).stat().st_ino, lock_inode)


if __name__ == "__main__":
    unittest.main()
