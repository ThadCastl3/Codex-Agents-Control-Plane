"""Offline output planning regressions; SDK clients and image processing are mocked."""

from contextlib import redirect_stderr, redirect_stdout
import asyncio
import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "image_cli_outputs", REPO / "skills/.system/imagegen/scripts/image_gen.py"
)
image_cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(image_cli)
IMAGE_BYTES = b"mock image response"
DOWNSCALED_BYTES = b"mock downscaled response"
ENCODED_IMAGE = base64.b64encode(IMAGE_BYTES).decode()


class ImageCliOutputs(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="image-cli-outputs-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.input_image = self.root / "input.png"
        self.input_image.write_bytes(b"mock edit input")
        # No credentials are read and an unconfigured factory cannot load an SDK.
        self.key_check = self.enterContext(mock.patch.object(image_cli, "_ensure_api_key"))
        self.sync_factory = self.enterContext(mock.patch.object(
            image_cli, "_create_client", side_effect=AssertionError("unexpected SDK client creation")
        ))
        self.async_factory = self.enterContext(mock.patch.object(
            image_cli, "_create_async_client", side_effect=AssertionError("unexpected async SDK client creation")
        ))
        self.downscale = self.enterContext(mock.patch.object(
            image_cli, "_downscale_image_bytes", return_value=DOWNSCALED_BYTES
        ))

    def invoke(self, arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["image_gen.py", *arguments]):
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = image_cli.main()
        return code, stdout.getvalue(), stderr.getvalue()

    def arguments(self, mode, out, *extra):
        args = [mode, "--prompt", "Offline fixture", "--out", str(out)]
        if mode == "edit":
            args += ["--image", str(self.input_image)]
        return args + list(extra)

    def batch_arguments(self, jobs, out_dir, *extra):
        source = self.root / "jobs.jsonl"
        source.write_text("".join(json.dumps(job) + "\n" for job in jobs))
        return ["generate-batch", "--input", str(source), "--out-dir", str(out_dir),
                "--concurrency", "1", *extra]

    def tree(self):
        return {str(path.relative_to(self.root)): path.read_bytes() if path.is_file() else None
                for path in self.root.rglob("*")}

    def assert_preflight_refusal(self, arguments):
        before = self.tree()
        with self.assertRaises(SystemExit) as raised:
            self.invoke(arguments)
        self.assertNotEqual(raised.exception.code, 0)
        self.sync_factory.assert_not_called()
        self.async_factory.assert_not_called()
        self.assertEqual(self.tree(), before, "preflight refusal changed output files or directories")

    def mock_clients(self):
        def response(**payload):
            return SimpleNamespace(data=[SimpleNamespace(b64_json=ENCODED_IMAGE)
                                         for _ in range(int(payload.get("n", 1)))])

        sync = SimpleNamespace(images=SimpleNamespace(
            generate=mock.Mock(side_effect=response), edit=mock.Mock(side_effect=response)
        ))
        asynchronous = SimpleNamespace(images=SimpleNamespace(
            generate=mock.AsyncMock(side_effect=response)
        ))
        self.sync_factory.side_effect = None
        self.sync_factory.return_value = sync
        self.async_factory.side_effect = None
        self.async_factory.return_value = asynchronous
        return sync, asynchronous

    def test_generate_refuses_existing_primary_before_client_creation(self):
        output = self.root / "existing.png"
        output.write_bytes(b"keep primary")
        self.assert_preflight_refusal(self.arguments("generate", output))

    def test_edit_refuses_existing_primary_before_client_creation(self):
        output = self.root / "existing.png"
        output.write_bytes(b"keep primary")
        self.assert_preflight_refusal(self.arguments("edit", output))

    def test_generate_refuses_existing_derived_before_client_creation(self):
        output = self.root / "image.png"
        (self.root / "image-web.png").write_bytes(b"keep derived")
        self.assert_preflight_refusal(self.arguments("generate", output, "--downscale-max-dim", "100"))

    def test_edit_refuses_existing_derived_before_client_creation(self):
        output = self.root / "image.png"
        (self.root / "image-web.png").write_bytes(b"keep derived")
        self.assert_preflight_refusal(self.arguments("edit", output, "--downscale-max-dim", "100"))

    def test_later_multi_image_collision_is_checked_before_any_work(self):
        for mode in ("generate", "edit"):
            for derived in (False, True):
                with self.subTest(mode=mode, derived=derived):
                    folder = self.root / f"{mode}-{derived}"
                    folder.mkdir()
                    filename = "image-2-web.png" if derived else "image-2.png"
                    (folder / filename).write_bytes(b"keep later output")
                    self.assert_preflight_refusal(self.arguments(
                        mode, folder / "image.png", "--n", "2", "--downscale-max-dim", "100"
                    ))

    def test_later_batch_job_collision_is_checked_before_any_work(self):
        for derived in (False, True):
            with self.subTest(derived=derived):
                folder = self.root / f"batch-{derived}"
                folder.mkdir()
                (folder / ("later-web.png" if derived else "later.png")).write_bytes(b"keep later output")
                args = self.batch_arguments(
                    [{"prompt": "First", "out": "first.png"}, {"prompt": "Later", "out": "later.png"}],
                    folder, "--downscale-max-dim", "100",
                )
                self.assert_preflight_refusal(args)

    def test_duplicate_batch_primary_is_rejected_even_with_force(self):
        for force in (False, True):
            with self.subTest(force=force):
                args = self.batch_arguments(
                    [{"prompt": "First", "out": "same.png"}, {"prompt": "Second", "out": "same.png"}],
                    self.root / f"duplicate-{force}", *(["--force"] if force else []),
                )
                self.assert_preflight_refusal(args)

    def test_cross_job_primary_derived_collision_is_rejected_even_with_force(self):
        for force in (False, True):
            with self.subTest(force=force):
                args = self.batch_arguments(
                    [{"prompt": "First", "out": "image.png"}, {"prompt": "Second", "out": "image-web.png"}],
                    self.root / f"cross-job-{force}", "--downscale-max-dim", "100",
                    *(["--force"] if force else []),
                )
                self.assert_preflight_refusal(args)

    def test_case_only_batch_output_aliases_are_rejected_even_with_force(self):
        for force in (False, True):
            with self.subTest(force=force):
                args = self.batch_arguments(
                    [{"prompt": "First", "out": "Foo.png"}, {"prompt": "Second", "out": "foo.png"}],
                    self.root / f"case-alias-{force}", *(["--force"] if force else []),
                )
                self.assert_preflight_refusal(args)

    def test_unicode_normalization_batch_aliases_are_rejected_even_with_force(self):
        for force in (False, True):
            with self.subTest(force=force):
                args = self.batch_arguments(
                    [{"prompt": "First", "out": "\u00e9.png"},
                     {"prompt": "Second", "out": "e\u0301.png"}],
                    self.root / f"unicode-alias-{force}", *(["--force"] if force else []),
                )
                # Both paths are absent: reject the planned alias on every
                # platform before requesting images or creating output files.
                self.assert_preflight_refusal(args)

    def test_unicode_parent_directory_aliases_are_rejected_even_with_force(self):
        # The CLI flattens per-job names into one output directory. Exercise the
        # shared validator directly to require normalization of the whole path.
        paths = [self.root / "\u00e9" / "image.png", self.root / "e\u0301" / "image.png"]
        before = self.tree()
        for force in (False, True):
            with self.subTest(force=force):
                with redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        image_cli._preflight_output_paths(paths, force=force)
                self.assertNotEqual(raised.exception.code, 0)
                self.assertEqual(self.tree(), before)
                self.sync_factory.assert_not_called()
                self.async_factory.assert_not_called()

    def test_distinct_unicode_batch_outputs_remain_successful(self):
        _, asynchronous = self.mock_clients()
        for force in (False, True):
            with self.subTest(force=force):
                folder = self.root / f"unicode-distinct-{force}"
                names = ("\u00e9.png", "\u00e8.png")
                args = self.batch_arguments(
                    [{"prompt": "First", "out": names[0]}, {"prompt": "Second", "out": names[1]}],
                    folder, *(["--force"] if force else []),
                )
                self.assertEqual(self.invoke(args)[0], 0)
                self.assertEqual(len(list(folder.iterdir())), 2)
                for name in names:
                    self.assertEqual((folder / name).read_bytes(), IMAGE_BYTES)
        self.assertEqual(asynchronous.images.generate.await_count, 4)
        self.sync_factory.assert_not_called()

    def test_empty_downscale_suffix_cannot_overwrite_primary(self):
        for mode in ("generate", "edit", "generate-batch"):
            with self.subTest(mode=mode):
                extra = ["--downscale-max-dim", "100", "--downscale-suffix", "", "--force"]
                if mode == "generate-batch":
                    args = self.batch_arguments([{"prompt": "First", "out": "image.png"}], self.root / mode, *extra)
                else:
                    args = self.arguments(mode, self.root / f"{mode}.png", *extra)
                self.assert_preflight_refusal(args)

    def test_force_rejects_existing_hardlink_and_symlink_output_aliases(self):
        for link_type in ("hardlink", "symlink"):
            with self.subTest(link_type=link_type):
                folder = self.root / link_type
                folder.mkdir()
                first, second = folder / "first.png", folder / "second.png"
                first.write_bytes(b"shared existing output")
                if link_type == "hardlink":
                    os.link(first, second)
                else:
                    second.symlink_to(first)
                args = self.batch_arguments(
                    [{"prompt": "First", "out": "first.png"}, {"prompt": "Second", "out": "second.png"}],
                    folder, "--force",
                )
                self.assert_preflight_refusal(args)
                if link_type == "symlink":
                    self.assertTrue(second.is_symlink())
                self.assertEqual(first.stat().st_ino, second.stat().st_ino)

    def test_force_allows_distinct_existing_primary_and_derived_outputs(self):
        sync, asynchronous = self.mock_clients()
        for mode in ("generate", "edit", "generate-batch"):
            with self.subTest(mode=mode):
                folder = self.root / mode
                folder.mkdir()
                output, derived = folder / "image.png", folder / "image-web.png"
                output.write_bytes(b"old primary")
                derived.write_bytes(b"old derived")
                extra = ["--force", "--downscale-max-dim", "100"]
                args = (self.batch_arguments([{"prompt": "First", "out": "image.png"}], folder, *extra)
                        if mode == "generate-batch" else self.arguments(mode, output, *extra))
                self.assertEqual(self.invoke(args)[0], 0)
                self.assertEqual(output.read_bytes(), IMAGE_BYTES)
                self.assertEqual(derived.read_bytes(), DOWNSCALED_BYTES)
        sync.images.generate.assert_called_once()
        sync.images.edit.assert_called_once()
        asynchronous.images.generate.assert_awaited_once()

    def test_successful_generate_and_edit_write_all_mocked_results(self):
        sync, _ = self.mock_clients()
        for mode in ("generate", "edit"):
            with self.subTest(mode=mode):
                folder = self.root / mode
                args = self.arguments(mode, folder / "image.png", "--n", "2", "--downscale-max-dim", "100")
                self.assertEqual(self.invoke(args)[0], 0)
                for number in (1, 2):
                    self.assertEqual((folder / f"image-{number}.png").read_bytes(), IMAGE_BYTES)
                    self.assertEqual((folder / f"image-{number}-web.png").read_bytes(), DOWNSCALED_BYTES)
        sync.images.generate.assert_called_once()
        sync.images.edit.assert_called_once()
        self.async_factory.assert_not_called()

    def test_successful_batch_writes_every_mocked_job_and_image(self):
        _, asynchronous = self.mock_clients()
        folder = self.root / "batch"
        args = self.batch_arguments(
            [{"prompt": "First", "out": "first.png", "n": 2}, {"prompt": "Second", "out": "second.png"}],
            folder, "--downscale-max-dim", "100",
        )
        self.assertEqual(self.invoke(args)[0], 0)
        for name in ("first-1", "first-2", "second"):
            self.assertEqual((folder / f"{name}.png").read_bytes(), IMAGE_BYTES)
            self.assertEqual((folder / f"{name}-web.png").read_bytes(), DOWNSCALED_BYTES)
        self.assertEqual(asynchronous.images.generate.await_count, 2)
        self.sync_factory.assert_not_called()

    def test_short_and_empty_responses_leave_no_empty_extra_outputs(self):
        for mode in ("generate", "edit", "generate-batch"):
            for count in (0, 1):
                with self.subTest(mode=mode, returned_images=count):
                    sync, asynchronous = self.mock_clients()
                    response = SimpleNamespace(data=[SimpleNamespace(b64_json=ENCODED_IMAGE)
                                                     for _ in range(count)])
                    for request in (sync.images.generate, sync.images.edit, asynchronous.images.generate):
                        request.side_effect = None
                        request.return_value = response
                    folder = self.root / f"short-{mode}-{count}"
                    extra = ["--n", "2", "--downscale-max-dim", "100"]
                    args = (self.batch_arguments([{"prompt": "First", "out": "image.png"}], folder, *extra)
                            if mode == "generate-batch" else self.arguments(mode, folder / "image.png", *extra))
                    self.assertEqual(self.invoke(args)[0], 0)
                    actual = {path.name: path.read_bytes() for path in folder.glob("*")} if folder.exists() else {}
                    expected = ({"image-1.png": IMAGE_BYTES, "image-1-web.png": DOWNSCALED_BYTES}
                                if count else {})
                    self.assertEqual(actual, expected)

    def test_batch_late_collision_handles_continue_and_fail_fast(self):
        for fail_fast in (False, True):
            with self.subTest(fail_fast=fail_fast):
                _, asynchronous = self.mock_clients()
                folder = self.root / f"late-batch-{fail_fast}"
                collision = folder / "first-web.png"

                async def response(**payload):
                    if "First" in payload["prompt"]:
                        folder.mkdir(exist_ok=True)
                        collision.write_bytes(b"late external output")
                    elif fail_fast:
                        # Keep the later request pending so cancellation is observable.
                        await asyncio.sleep(30)
                    return SimpleNamespace(data=[SimpleNamespace(b64_json=ENCODED_IMAGE)])

                asynchronous.images.generate.side_effect = response
                args = self.batch_arguments(
                    [{"prompt": "First", "out": "first.png"}, {"prompt": "Second", "out": "second.png"}],
                    folder, "--downscale-max-dim", "100", *(["--fail-fast"] if fail_fast else []),
                )
                # Obtain the actual CLI-parsed Namespace, then inspect the async
                # batch boundary directly so a job's SystemExit cannot escape unnoticed.
                with mock.patch.object(image_cli, "_generate_batch") as dispatch:
                    self.assertEqual(self.invoke(args)[0], 0)
                parsed = dispatch.call_args.args[0]
                unhandled = []

                async def run_batch():
                    asyncio.get_running_loop().set_exception_handler(lambda _loop, context: unhandled.append(context))
                    return await asyncio.wait_for(image_cli._run_generate_batch(parsed), timeout=1)

                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    if fail_fast:
                        with self.assertRaises(RuntimeError):
                            asyncio.run(run_batch())
                    else:
                        self.assertEqual(asyncio.run(run_batch()), 1)
                self.assertEqual(unhandled, [])
                self.assertFalse((folder / "first.png").exists())
                self.assertEqual(collision.read_bytes(), b"late external output")
                if fail_fast:
                    self.assertFalse((folder / "second.png").exists())
                else:
                    self.assertEqual((folder / "second.png").read_bytes(), IMAGE_BYTES)
                    self.assertEqual((folder / "second-web.png").read_bytes(), DOWNSCALED_BYTES)

    def test_dry_run_previews_without_client_or_output_directory_creation(self):
        for mode in ("generate", "edit", "generate-batch"):
            with self.subTest(mode=mode):
                folder = self.root / f"preview-{mode}"
                extra = ["--dry-run", "--downscale-max-dim", "100"]
                args = (self.batch_arguments([{"prompt": "First", "out": "image.png"}], folder, *extra)
                        if mode == "generate-batch" else self.arguments(mode, folder / "unused.png", "--out-dir", str(folder), *extra))
                before = self.tree()
                code, output, _ = self.invoke(args)
                self.assertEqual(code, 0)
                preview = json.loads(output)
                self.assertIn("outputs", preview)
                self.assertIn("outputs_downscaled", preview)
                self.assertEqual(self.tree(), before)
                self.sync_factory.assert_not_called()
                self.async_factory.assert_not_called()

    def test_dry_run_still_previews_existing_outputs(self):
        output = self.root / "existing.png"
        output.write_bytes(b"keep output")
        before = self.tree()
        code, preview, _ = self.invoke(self.arguments("generate", output, "--dry-run"))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(preview)["outputs"], [str(output)])
        self.assertEqual(self.tree(), before)
        self.sync_factory.assert_not_called()

    def test_post_response_derived_collision_cannot_leave_partial_primary(self):
        output = self.root / "image.png"
        derived = self.root / "image-web.png"
        derived.write_bytes(b"created after request")
        before = self.tree()
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                image_cli._decode_write_and_downscale(
                    [ENCODED_IMAGE], [output], force=False, downscale_max_dim=100,
                    downscale_suffix="-web", output_format="png",
                )
        self.assertEqual(self.tree(), before)
        self.downscale.assert_not_called()

    def test_reservation_race_cleans_primary_and_preserves_late_output(self):
        output, derived = self.root / "image.png", self.root / "image-web.png"
        original_open = Path.open

        def collide_during_reservation(path, mode="r", *args, **kwargs):
            if path == derived and mode == "xb":
                with original_open(path, "wb") as stream:
                    stream.write(b"late reservation sentinel")
            return original_open(path, mode, *args, **kwargs)

        with mock.patch.object(Path, "open", new=collide_during_reservation):
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    image_cli._decode_write_and_downscale(
                        [ENCODED_IMAGE], [output], force=False, downscale_max_dim=100,
                        downscale_suffix="-web", output_format="png",
                    )
        self.assertFalse(output.exists(), "failed reservation left an empty primary file")
        self.assertEqual(derived.read_bytes(), b"late reservation sentinel")


if __name__ == "__main__":
    unittest.main()
