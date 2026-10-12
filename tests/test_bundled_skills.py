"""Offline regressions for the separately maintained bundled skills."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
CREATOR = REPO / 'skills/.system/skill-creator/scripts'
INSTALLER = REPO / 'skills/.system/skill-installer/scripts'


def load_helper(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    original = list(sys.path)
    try:
        sys.path.insert(0, str(path.parent))
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = original
    return module


class BundledCliTests(unittest.TestCase):
    def test_docs_symlink_timeout_and_cache(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('Node.js is required for the optional docs helper')
        result = subprocess.run(
            [node, str(REPO / 'tests/fixtures/docs-helper-regressions.mjs'),
             str(REPO / 'skills/.system/openai-docs/scripts/fetch-codex-manual.mjs')],
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_playwright_session_and_argument_forwarding(self):
        cases = [
            ([], None, []),
            (['snapshot'], 'default', ['--session', 'default', 'snapshot']),
            (['--session', 'chosen', 'snapshot'], 'default', ['--session', 'chosen', 'snapshot']),
            (['--session=chosen', 'snapshot'], 'default', ['--session=chosen', 'snapshot']),
            (['-s', 'chosen', 'snapshot'], 'default', ['-s', 'chosen', 'snapshot']),
            (['-s=chosen', 'snapshot'], 'default', ['-s=chosen', 'snapshot']),
            (['fill', 'e1', 'text with spaces; $(not-a-command)'], None,
             ['fill', 'e1', 'text with spaces; $(not-a-command)']),
        ]
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            shim = folder / 'npx'
            shim.write_text('#!' + sys.executable + '\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
            shim.chmod(0o755)
            for args, session, expected in cases:
                with self.subTest(args=args):
                    env = dict(os.environ, PATH=str(folder) + os.pathsep + os.environ['PATH'])
                    env.pop('PLAYWRIGHT_CLI_SESSION', None)
                    if session:
                        env['PLAYWRIGHT_CLI_SESSION'] = session
                    result = subprocess.run(
                        ['bash', str(REPO / 'skills/playwright/scripts/playwright_cli.sh'), *args],
                        env=env, capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout),
                        ['--yes', '--package', '@playwright/cli@0.1.19', 'playwright-cli', *expected])


class BundledCreatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            cls.validator = load_helper('bundled_quick_validate', CREATOR / 'quick_validate.py')
        except ModuleNotFoundError as error:
            if error.name == 'yaml':
                raise unittest.SkipTest('PyYAML is required for the optional skill-creator helpers')
            raise

    def validate(self, body):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            (folder / 'SKILL.md').write_text(
                '---\nname: fixture\ndescription: Validate the requested fixture.\n---\n' + body + '\n')
            return self.validator.validate_skill(folder)[0]

    def test_literal_indented_fence_cannot_hide_unfinished_guidance(self):
        for indent in ['    ', '\t']:
            with self.subTest(indent=repr(indent)):
                self.assertFalse(self.validate(indent + '```\n' + indent + 'literal code\n\n[TODO: Finish guidance.]'))

    def test_literal_indented_close_preserves_fenced_example(self):
        self.assertTrue(self.validate('```markdown\n    ```\n[TODO: Example only.]\n```'))
        self.assertTrue(self.validate('- ```markdown\n      ```\n  [TODO: Example only.]\n  ```'))

    def test_dedenting_list_fence_exposes_unfinished_guidance(self):
        self.assertFalse(self.validate('- ```markdown\n  [TODO: Example only.]\n[TODO: Finish guidance.]'))
        self.assertFalse(self.validate('- ```markdown\n  [TODO: Example only.]\n    ```\n[TODO: Finish guidance.]'))

    def test_all_bundled_entrypoints_validate(self):
        for folder in [*sorted((REPO / 'skills/.system').glob('*/')), REPO / 'skills/playwright']:
            if (folder / 'SKILL.md').is_file():
                with self.subTest(skill=folder.name):
                    valid, reason = self.validator.validate_skill(folder)
                    self.assertTrue(valid, reason)


class BundledInstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.installer = load_helper('bundled_installer', INSTALLER / 'install-skill-from-github.py')

    def test_internal_file_link_is_copied_as_regular_file(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve()
            skill = root / 'repo/skills/fixture'
            skill.mkdir(parents=True)
            (skill / 'SKILL.md').write_text('Fixture instructions')
            (skill / 'reference.md').write_text('Fixture reference')
            (skill / 'alias.md').symlink_to('reference.md')
            self.installer._validate_skill(str(skill), str(root / 'repo'))
            destination = root / 'installed/fixture'
            self.installer._copy_skill(str(skill), str(destination))
            self.assertFalse((destination / 'alias.md').is_symlink())
            self.assertEqual((destination / 'alias.md').read_text(), 'Fixture reference')

    def test_external_file_link_is_rejected_before_copy(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve()
            skill = root / 'repo/skills/fixture'
            skill.mkdir(parents=True)
            (skill / 'SKILL.md').write_text('Fixture instructions')
            (root / 'outside.md').write_text('Outside selected skill')
            (skill / 'alias.md').symlink_to(root / 'outside.md')
            with self.assertRaises(self.installer.InstallError):
                self.installer._validate_skill(str(skill), str(root / 'repo'))


if __name__ == '__main__':
    unittest.main()
