"""Regression checks for the acceptance runner using isolated fake CLI processes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "scripts" / "macus-acceptance.py"


class MacusAcceptanceTests(unittest.TestCase):
    def run_fixture(self, mode):
        with tempfile.TemporaryDirectory(prefix="macus-acceptance-test-") as folder:
            root = Path(folder)
            state = root / "state"
            state.mkdir()
            incus = root / "incus"
            macus = root / "macus"
            incus.write_text(
                "#!" + sys.executable + "\n"
                "import os, pathlib, sys\n"
                "conf = pathlib.Path(os.environ['INCUS_CONF'])\n"
                "if sys.argv[1:] == ['remote', 'get-default']:\n"
                "    if os.environ['MACUS_ACCEPTANCE_TEST_MODE'] == 'read-fails':\n"
                "        sys.exit(1)\n"
                "    stored = conf / 'default'\n"
                "    print(stored.read_text() if stored.exists() else 'local')\n"
                "elif sys.argv[1] != 'list':\n"
                "    sys.exit(2)\n"
            )
            macus.write_text(
                "#!" + sys.executable + "\n"
                "import json, os, pathlib, sys\n"
                "conf = pathlib.Path(os.environ['INCUS_CONF'])\n"
                "if os.environ['MACUS_ACCEPTANCE_TEST_MODE'] == 'changes-default':\n"
                "    (conf / 'default').write_text('other')\n"
                "print(json.dumps({'remote': 'macus', 'connected': True, 'installed': False}))\n"
            )
            incus.chmod(0o755)
            macus.chmod(0o755)
            report = root / "report.json"
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--state-dir", str(state),
                 "--macus", str(macus), "--incus", str(incus), "--report", str(report)],
                env=dict(os.environ, MACUS_ACCEPTANCE_TEST_MODE=mode, TMPDIR=str(root)),
                text=True, capture_output=True, timeout=15,
            )
            data = json.loads(report.read_text())
            return result, data

    def test_preserved_default_passes(self):
        result, report = self.run_fixture("preserves-default")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["default_before"], "local")
        self.assertEqual(report["default_after"], "local")
        self.assertTrue(report["checks"]["default_unchanged"])
        self.assertTrue(report["success"])

    def test_change_to_unrelated_default_fails(self):
        result, report = self.run_fixture("changes-default")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report["default_before"], "local")
        self.assertEqual(report["default_after"], "other")
        self.assertFalse(report["checks"]["default_unchanged"])
        self.assertNotIn("success", report)

    def test_failed_initial_default_read_prevents_setup(self):
        result, report = self.run_fixture("read-fails")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(report["commands"]), 1)
        self.assertEqual(report["commands"][0]["tool"], "incus")
        self.assertNotIn("registered", report["checks"])


if __name__ == "__main__":
    unittest.main()
