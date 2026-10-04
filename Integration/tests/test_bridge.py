"""Listener regressions run without vsock or a guest VM."""
import errno
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

BRIDGE = Path(__file__).resolve().parents[1] / 'guest' / 'bridge.py'
spec = importlib.util.spec_from_file_location('bridge', BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def test_transient_accept_errors_retry_but_fatal_errors_propagate(self):
        listener = mock.MagicMock()
        listener.__enter__.return_value = listener
        listener.accept.side_effect = [OSError(errno.EINTR, 'interrupted'),
                                       OSError(errno.EMFILE, 'busy'),
                                       OSError(errno.EINVAL, 'fatal')]
        ready = bridge.threading.Event()
        with mock.patch.object(bridge.socket, 'AF_VSOCK', 40, create=True), \
                mock.patch.object(bridge.socket, 'VMADDR_CID_ANY', -1, create=True), \
                mock.patch.object(bridge.socket, 'socket', return_value=listener), \
                mock.patch.object(bridge.time, 'sleep') as sleep:
            with self.assertRaises(OSError):
                bridge.serve(8443, lambda _: None, ready)
        self.assertEqual(listener.accept.call_count, 3)
        sleep.assert_called_once_with(0.1)
        self.assertFalse(ready.is_set())

    def test_health_waits_for_relay_listener(self):
        client = mock.Mock()
        client.recv.return_value = b'GET /health HTTP/1.1\r\n\r\n'
        bridge.relay_ready.clear()
        with mock.patch.object(bridge, 'incus_health', return_value={'protocol_version': 1}) as probe:
            bridge.health(client)
            self.assertTrue(client.sendall.call_args.args[0].startswith(b'HTTP/1.1 503'))
            probe.assert_not_called()
            bridge.relay_ready.set()
            bridge.health(client)
            self.assertTrue(client.sendall.call_args.args[0].startswith(b'HTTP/1.1 200'))
        bridge.relay_ready.clear()

    def test_fatal_listener_exits_even_with_blocked_worker(self):
        # A real subprocess catches executor context-manager shutdown deadlocks.
        script = f'''
import importlib.util, errno, threading
from unittest import mock
spec = importlib.util.spec_from_file_location("bridge", {str(BRIDGE)!r})
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
blocked = threading.Event()
entered = threading.Event()
client = mock.MagicMock()
listener = mock.MagicMock()
listener.__enter__.return_value = listener
def handler(_):
    entered.set()
    blocked.wait()
def accept():
    if not entered.is_set():
        # Submit exactly one indefinitely blocked stream.
        listener.accept.side_effect = fatal
        return client, (2, 123)
def fatal():
    assert entered.wait(2)
    raise OSError(errno.EINVAL, "permanent accept failure")
listener.accept.side_effect = accept
with mock.patch.object(b.socket, "AF_VSOCK", 40, create=True), mock.patch.object(b.socket, "VMADDR_CID_ANY", -1, create=True), mock.patch.object(b.socket, "socket", return_value=listener):
    b.run_or_exit(8443, handler)
'''
        result = subprocess.run([sys.executable, '-c', script], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stderr.decode())
        self.assertIn(b'permanent accept failure', result.stderr)

    def test_bind_failure_exits_process(self):
        script = f'''
import importlib.util
spec = importlib.util.spec_from_file_location("bridge", {str(BRIDGE)!r})
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
def fail(*_):
    raise OSError("bind failure")
b.serve = fail
b.run_or_exit(8444, b.health)
'''
        result = subprocess.run([sys.executable, '-c', script], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'bind failure', result.stderr)


if __name__ == '__main__':
    unittest.main()
