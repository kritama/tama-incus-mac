"""The start acceptance runner must refuse ordinary user state and retain failures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "scripts" / "start-acceptance.py"


class StartAcceptanceTests(unittest.TestCase):
    def test_refuses_ordinary_state_and_does_not_execute(self):
        with tempfile.TemporaryDirectory(prefix="macus-start-accept-") as folder:
            root = Path(folder)
            sentinel = root / "executed"
            macus = root / "macus"
            macus.write_text("#!/bin/sh\ntouch \"$MACUS_ACCEPTANCE_SENTINEL\"\n")
            macus.chmod(0o755)
            report = root / "report.json"
            env = dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel))
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--opt-in", "--state-dir",
                 str(Path.home() / ".tama" / "incus-mac"), "--prefix", str(root / "prefix"),
                 "--macus", str(macus), "--report", str(report)],
                env=env, text=True, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing", result.stderr)
            self.assertFalse(sentinel.exists())
            self.assertFalse(report.exists())

    def test_without_hardware_preserves_report_and_does_not_execute(self):
        with tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
            root = Path(folder)
            state = root / "state"
            sentinel = root / "executed"
            marker = state / "keep"
            macus = root / "macus"
            macus.write_text("#!/bin/sh\ntouch \"$MACUS_ACCEPTANCE_SENTINEL\"\n")
            macus.chmod(0o755)
            report = root / "report.json"
            env = dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(sentinel))
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--opt-in", "--state-dir", str(state),
                 "--prefix", str(root / "prefix"), "--macus", str(macus), "--report", str(report)],
                env=env, text=True, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertFalse(sentinel.exists())
            data = json.loads(report.read_text())
            self.assertFalse(data["hardware_ran"])
            self.assertFalse(data["guest_verified"])
            self.assertFalse(data["brew_install_ran"])
            self.assertNotIn("success", data)
            state.mkdir(exist_ok=True)
            marker.write_text("preserve\n")
            failed = root / "fail-macus"
            failed.write_text("#!/bin/sh\nexit 1\n")
            failed.chmod(0o755)
            failed_report = root / "failed.json"
            failed_run = subprocess.run(
                [sys.executable, str(RUNNER), "--opt-in", "--hardware", "--state-dir", str(state),
                 "--prefix", str(root / "prefix"), "--macus", str(failed),
                 "--report", str(failed_report)],
                env=env, text=True, capture_output=True, timeout=15)
            self.assertNotEqual(failed_run.returncode, 0)
            self.assertEqual(marker.read_text(), "preserve\n")
            failed_data = json.loads(failed_report.read_text())
            self.assertFalse(failed_data.get("success", False))
            self.assertTrue(failed_data["hardware_ran"])
            self.assertFalse(failed_data["guest_verified"])

    def test_report_inside_runtime_does_not_destroy_data_or_run(self):
        sentinel = b"INCUS-DATA-SENTINEL\n"
        for hardware in (False, True):
            with self.subTest(hardware=hardware), tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
                root = Path(folder)
                state = root / "state"
                disk = state / "runtime" / "data.raw"
                disk.parent.mkdir(parents=True)
                disk.write_bytes(sentinel)
                executed = root / "executed"
                macus = root / "macus"
                macus.write_text("#!/bin/sh\ntouch \"$MACUS_ACCEPTANCE_SENTINEL\"\n")
                macus.chmod(0o755)
                command = [
                    sys.executable, str(RUNNER), "--opt-in", "--state-dir", str(state),
                    "--prefix", str(root / "prefix"), "--macus", str(macus),
                    "--report", str(disk),
                ]
                if hardware:
                    command.append("--hardware")
                result = subprocess.run(
                    command, env=dict(os.environ, MACUS_ACCEPTANCE_SENTINEL=str(executed)),
                    text=True, capture_output=True, timeout=15)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("Refusing", result.stderr)
                self.assertEqual(disk.read_bytes(), sentinel)
                self.assertFalse(executed.exists())
                self.assertFalse((root / "prefix").exists())

    def test_symlink_report_is_rejected_before_mutation(self):
        with tempfile.TemporaryDirectory(prefix="msa", dir="/tmp") as folder:
            root = Path(folder)
            state = root / "state"
            disk = state / "runtime" / "data.raw"
            disk.parent.mkdir(parents=True)
            disk.write_bytes(b"INCUS-DATA-SENTINEL\n")
            link = root / "report-link"
            link.symlink_to(disk)
            macus = root / "macus"
            macus.write_text("#!/bin/sh\nexit 0\n")
            macus.chmod(0o755)
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--opt-in", "--state-dir", str(state),
                 "--prefix", str(root / "prefix"), "--macus", str(macus), "--report", str(link)],
                text=True, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink", result.stderr)
            self.assertEqual(disk.read_bytes(), b"INCUS-DATA-SENTINEL\n")
            self.assertFalse(link.is_file() and link.read_bytes().startswith(b"{"))


if __name__ == "__main__":
    unittest.main()
