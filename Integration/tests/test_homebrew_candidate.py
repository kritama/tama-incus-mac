"""Packaging guards run without installing packages or booting hardware."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

FILE = Path(__file__).resolve().parents[2] / "Packaging/homebrew/candidate.py"
SPEC = importlib.util.spec_from_file_location("candidate", FILE)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


class CandidateTests(unittest.TestCase):
    def repo(self, root):
        repo = root / "source"
        repo.mkdir()
        for arguments in (["init", "-b", "main"], ["config", "user.name", "Fixture"],
                          ["config", "user.email", "fixture@localhost"]):
            candidate.run(["git", *arguments], cwd=repo)
        (repo / "Package.swift").write_text("// fixture\n")
        template = repo / "Packaging/homebrew/Formula/macus.rb.in"
        template.parent.mkdir(parents=True)
        template.write_text(candidate.TEMPLATE.read_text())
        candidate.run(["git", "add", "."], cwd=repo)
        candidate.run(["git", "commit", "--no-gpg-sign", "-m", "Fixture"], cwd=repo)
        return repo

    def prepared(self, root):
        with patch.object(candidate, "run", wraps=candidate.run) as command:
            def execute(arguments, **kwargs):
                if arguments == ["swift", "--version"]:
                    return "Swift 6.4 fixture"
                return command._mock_wraps(arguments, **kwargs)
            command.side_effect = execute
            return candidate.prepare(root / "output", repo=self.repo(root), stamp="20261008000000")

    def test_clean_provenance_and_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data = self.prepared(Path(directory))
            self.assertEqual(candidate.load(root)[1], data)
            self.assertIn(data["source_commit"][:12], data["version"])
            self.assertNotIn("@SOURCE", (root / "tap/Formula/macus.rb").read_text())
            (root / data["source_file"]).write_bytes(b"corrupted")
            with self.assertRaisesRegex(ValueError, "integrity"):
                candidate.load(root)

    def test_dirty_source_and_existing_output_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = self.repo(root)
            (repo / "uncommitted").write_text("work")
            with self.assertRaisesRegex(ValueError, "clean committed"):
                candidate.prepare(root / "output", repo=repo)
            self.assertFalse((root / "output").exists())
            (repo / "uncommitted").unlink()
            (root / "output").mkdir()
            with self.assertRaisesRegex(ValueError, "reuse"):
                candidate.prepare(root / "output", repo=repo)

    def test_symlink_output_and_artifact_traversal_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "alias").symlink_to(folder, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlink"):
                candidate.safe_path(folder / "alias/output")
            root, data = self.prepared(folder)
            data["source_file"] = "../outside.tar.gz"
            (root / "candidate.json").write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "integrity"):
                candidate.load(root)

    def test_mutations_require_opt_in_before_executing(self):
        for action in (candidate.build, candidate.install):
            with patch.object(candidate, "run") as command:
                with self.assertRaisesRegex(ValueError, "opt-in"):
                    action(argparse.Namespace(opt_in=False, candidate=Path("/missing")))
                command.assert_not_called()

    def test_conflict_does_not_replace_package(self):
        result = subprocess.CompletedProcess([], 0, "macus 0.1\n", "")
        with patch.object(candidate.subprocess, "run", return_value=result) as command:
            with self.assertRaisesRegex(ValueError, "existing Macus"):
                candidate.refuse_package_conflict()
            self.assertEqual(command.call_count, 1)

    def test_real_digests_arm64_tags_and_ruby_interpolation(self):
        for value in ("", "0" * 64, "not-a-digest"):
            with self.assertRaises(ValueError):
                candidate.checked_sha(value)
        self.assertIn("\\#{", candidate.ruby_string('#{raise "injected"}'))
        manifest = {"source_url": "file:///fixture.tar.gz", "version": "fixture",
                    "source_sha256": "ab" * 32, "bottle_root": "file:///fixture",
                    "bottles": {"all": {"cellar": "any", "sha256": "cd" * 32}}}
        with self.assertRaisesRegex(ValueError, "ARM64"):
            candidate.render(manifest)

    def test_export_refuses_local_urls_before_network_or_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root, data = self.prepared(Path(directory))
            bottle = root / "macus.bottle.tar.gz"
            bottle.write_bytes(b"fixture-bottle")
            data["bottles"] = {"arm64_fixture": {"filename": bottle.name,
                              "local_filename": bottle.name, "sha256": candidate.digest(bottle), "cellar": "any"}}
            candidate.save(root, data)
            destination = root / "exported.rb"
            args = argparse.Namespace(candidate=root, source_url=data["source_url"],
                                      bottle_root=root.as_uri(), destination=destination)
            with patch.object(candidate, "urlopen") as network:
                with self.assertRaisesRegex(ValueError, "immutable HTTPS"):
                    candidate.export(args)
                network.assert_not_called()
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
