"""Presentation acceptance must distinguish unsupported hosts and exercise real runtime waits."""
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "presentation-acceptance.py"
spec = importlib.util.spec_from_file_location("presentation_acceptance", SCRIPT)
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class PresentationAcceptanceTests(unittest.TestCase):
    def fixture(self, root):
        return SimpleNamespace(root=root, calls=[], dispatched=threading.Event(), state="ready", mode="success")

    def test_unsupported_host_checks_rejection_without_accepting_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(Path(temporary))
            calls = []

            def invoke(binary, arguments, env, interactive=False, interrupt=None, translate_newlines=True):
                calls.append(arguments)
                if "--json" in arguments:
                    return 1, "", json.dumps({"error": {"code": "unavailable", "message": "Apple virtualization is unavailable"}})
                text = "Apple virtualization is unavailable\nMacus failed (unavailable)\n"
                return (1, "\x1b[?25h" + text, "") if interactive else (1, "", text)

            report = {"transcripts": {}}
            with patch.object(acceptance, "invoke", side_effect=invoke):
                acceptance.verify_startup(Path("/fixture/macus"), Path("/fixture/incus"), {}, fixture, report, False)
            self.assertEqual(report["startup_fixture_mode"], "unsupported-host rejection")
            self.assertEqual(len(calls), 3)
            self.assertEqual(len(report["transcripts"]), 3)
            self.assertTrue(all("unsupported host" in name for name in report["transcripts"]))
            self.assertFalse(fixture.dispatched.is_set())

    def test_unsupported_host_cannot_silently_accept_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(Path(temporary))
            with patch.object(acceptance, "invoke", return_value=(0, "Macus is ready\n", "")):
                with self.assertRaises(AssertionError):
                    acceptance.verify_startup(Path("/fixture/macus"), Path("/fixture/incus"), {}, fixture, {"transcripts": {}}, False)

    def timeout_invoker(self, fixture, dispatch):
        def invoke(binary, arguments, env, interactive=False, interrupt=None, translate_newlines=True):
            if "--json" in arguments:
                return 0, '{"ready":true,"connected":true}', ""
            if "--timeout" not in arguments:
                return (0, "\x1b[?25hMacus is ready\r\n", "") if interactive else (0, "Macus is ready\n", "")
            if fixture.mode == "timeout":
                self.assertEqual(arguments[arguments.index("--timeout") + 1], "5")
                if dispatch:
                    fixture.dispatched.set()
                return 1, "⨯ Waiting for Incus failed [0.1s]\r\n\x1b[?25h  Macus failed (timeout)\r\nruntime status\r\nruntime stop\r\n", ""
            fixture.dispatched.set()
            code = 130 if fixture.mode == "cancellation" else 1
            return code, "⨯ Waiting for Incus failed [0.1s]\r\n\x1b[?25h  Macus failed\r\nruntime status\r\nruntime stop\r\n", ""
        return invoke

    def test_preflight_timeout_cannot_pass_runtime_wait_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(Path(temporary))
            with patch.object(acceptance, "invoke", side_effect=self.timeout_invoker(fixture, False)), patch.object(acceptance, "check_native_startup_screen", return_value=[]):
                with self.assertRaisesRegex(AssertionError, "runtime start was never dispatched"):
                    acceptance.verify_startup(Path("/fixture/macus"), Path("/fixture/incus"), {}, fixture, {"transcripts": {}}, True)

    def test_dispatched_runtime_wait_retains_full_startup_matrix(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(Path(temporary))
            report = {"transcripts": {}}
            with patch.object(acceptance, "invoke", side_effect=self.timeout_invoker(fixture, True)), patch.object(acceptance, "check_native_startup_screen", return_value=[]):
                acceptance.verify_startup(Path("/fixture/macus"), Path("/fixture/incus"), {}, fixture, report, True)
            self.assertEqual(report["startup_fixture_mode"], "supported-host runtime fixtures")
            self.assertEqual(len(report["transcripts"]), 8)
            self.assertIn("pty start timeout", report["transcripts"])

class TerminalScreenTests(unittest.TestCase):
    def test_completed_step_does_not_implicitly_return_to_margin(self):
        broken = "\r\x1b[2K✔︎ Host checked [0.1s]\n⠋ Downloading\r\x1b[2K✔︎ Service activated [0.1s]\nMacus is ready\n"
        rows = acceptance.TerminalScreen().feed(broken).rows
        self.assertNotIn("Macus is ready", rows)
        with self.assertRaises(AssertionError):
            acceptance.check_native_startup_screen(broken)

    def test_native_rows_and_summary_survive_color_and_explicit_column_returns(self):
        text = "\x1b[?25l\r\x1b[2K⠋ Checking host\r\x1b[2K"
        for label in ['Host checked', 'Service activated', 'Incus is ready', 'Client connected']:
            text += f"\x1b[32m✔︎ {label}\x1b[0m [0.1s]\n\r"
        text += "\x1b[?25hStartup: 9/9 stages resolved\n\rMacus is ready\n\r"
        rows = acceptance.check_native_startup_screen(text)
        self.assertEqual(rows[0], "✔︎ Host checked [0.1s]")
        self.assertEqual(rows[-1], "Macus is ready")
