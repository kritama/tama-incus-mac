import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import hashlib
import json
from unittest.mock import patch

FILE = Path(__file__).resolve().parents[1] / "scripts/homebrew-acceptance.py"
SPEC = importlib.util.spec_from_file_location("homebrew_acceptance", FILE)
acceptance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acceptance)


class HomebrewAcceptanceTests(unittest.TestCase):
    def test_retry_completes_owned_marker_without_duplicate_launch(self):
        state = Path('/tmp/owned-test/state')
        value = {'name': 'macus-brew-marker', 'status': 'Running',
                 'config': {'user.macus.homebrew-acceptance': hashlib.sha256(str(state).encode()).hexdigest()}}
        with patch.object(acceptance, 'execute', side_effect=[json.dumps([value]), '']) as command:
            acceptance.ensure_marker('/incus', 'macus-brew:macus-brew-marker', {}, {}, state)
            calls = [args.args[0] for args in command.call_args_list]
            self.assertFalse(any('launch' in call for call in calls))
            self.assertEqual(calls[-1][1], 'exec')
        value['config'] = {}
        with patch.object(acceptance, 'execute', return_value=json.dumps([value])) as command:
            with self.assertRaisesRegex(ValueError, 'unrelated'):
                acceptance.ensure_marker('/incus', 'macus-brew:macus-brew-marker', {}, {}, state)
            self.assertEqual(command.call_count, 1)

    def test_resume_requires_stop_unload_and_new_candidate(self):
        with self.assertRaisesRegex(ValueError, 'stop and unload'):
            acceptance.require_upgrade({'checks': {}}, {'version': 'new'})
        report = {'checks': {'stopped_and_unloaded': True}, 'stopped_version': 'old'}
        with self.assertRaisesRegex(ValueError, 'different installed'):
            acceptance.require_upgrade(report, {'version': 'old'})
        acceptance.require_upgrade(report, {'version': 'new'})

    def test_launchd_label_matches_platform_aliases(self):
        self.assertEqual(acceptance.service_label(Path('/private/tmp/macus-brew/state')),
                         acceptance.service_label(Path('/tmp/macus-brew/state')))
        self.assertEqual(acceptance.service_label(Path('/private/var/macus-brew/state')),
                         acceptance.service_label(Path('/var/macus-brew/state')))
        self.assertNotEqual(acceptance.service_label(Path('/tmp/macus-brew/state')),
                            acceptance.service_label(Path('/tmp/other/state')))

    def test_refuses_without_opt_in_before_creating_state(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            root = Path(directory) / "fresh"
            result = subprocess.run([sys.executable, str(FILE), "--root", str(root),
                "--candidate", "/missing", "--phase", "start"], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("explicit --opt-in --hardware", result.stderr)
            self.assertFalse(root.exists())

    def test_refuses_ordinary_existing_and_relative_roots(self):
        with self.assertRaises(ValueError):
            acceptance.fixture_paths(Path.home(), first=True)
        with self.assertRaises(ValueError):
            acceptance.fixture_paths(Path("relative"), first=True)
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            root = Path(directory)
            (root / "sentinel").write_text("preserve")
            with self.assertRaises(ValueError):
                acceptance.fixture_paths(root, first=True)
            self.assertEqual((root / "sentinel").read_text(), "preserve")

    def test_refuses_symlink_state_client_and_report(self):
        for name in ("state", "client", "hardware.json"):
            with self.subTest(name=name), tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
                root = Path(directory)
                (root / name).symlink_to(root / "outside")
                with self.assertRaisesRegex(ValueError, "symlink"):
                    acceptance.fixture_paths(root)


if __name__ == "__main__":
    unittest.main()
