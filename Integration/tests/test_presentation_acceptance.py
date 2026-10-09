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

            def invoke(binary, arguments, env, interactive=False, interrupt=None):
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
        def invoke(binary, arguments, env, interactive=False, interrupt=None):
            if "--json" in arguments:
                return 0, '{"ready":true,"connected":true}', ""
            if "--timeout" not in arguments:
                return (0, "\x1b[?25h[complete] Macus is ready\r\nMacus is ready\r\n", "") if interactive else (0, "Macus is ready\n", "")
            if fixture.mode == "timeout":
                self.assertEqual(arguments[arguments.index("--timeout") + 1], "5")
                if dispatch:
                    fixture.dispatched.set()
                return 1, "Waiting for Incus\r\n\x1b[?25hMacus failed (timeout)\r\nruntime status\r\nruntime stop\r\n", ""
            fixture.dispatched.set()
            code = 130 if fixture.mode == "cancellation" else 1
            return code, "\x1b[?25hMacus failed\r\nruntime status\r\nruntime stop\r\n", ""
        return invoke

    def test_preflight_timeout_cannot_pass_runtime_wait_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(Path(temporary))
            with patch.object(acceptance, "invoke", side_effect=self.timeout_invoker(fixture, False)):
                with self.assertRaisesRegex(AssertionError, "runtime start was never dispatched"):
                    acceptance.verify_startup(Path("/fixture/macus"), Path("/fixture/incus"), {}, fixture, {"transcripts": {}}, True)

    def test_dispatched_runtime_wait_retains_full_startup_matrix(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(Path(temporary))
            report = {"transcripts": {}}
            with patch.object(acceptance, "invoke", side_effect=self.timeout_invoker(fixture, True)):
                acceptance.verify_startup(Path("/fixture/macus"), Path("/fixture/incus"), {}, fixture, report, True)
            self.assertEqual(report["startup_fixture_mode"], "supported-host runtime fixtures")
            self.assertEqual(len(report["transcripts"]), 6)
            self.assertIn("pty start timeout", report["transcripts"])
