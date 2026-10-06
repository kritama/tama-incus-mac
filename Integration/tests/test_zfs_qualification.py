"""Qualification must reject wrong storage and unsafe exhaustion before workloads."""
import http.server
import json
import os
from pathlib import Path
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest

RUNNER = Path(__file__).resolve().parents[1] / 'qualification/run-zfs.py'
PREPARE = Path(__file__).resolve().parents[1] / 'qualification/prepare-zfs.py'
INSTALL_LINE = (
    '    linux-lts=6.18.55-r0 zfs=2.4.4-r0 zfs-libs=2.4.4-r0 '
    'zfs-lts=6.18.55-r0 zfs-openrc=2.4.4-r0; then'
)
REBOOT_LINE = '    echo TAMA_ZFS_KERNEL_REBOOT_REQUIRED'
DIAGNOSTIC = (
    "    echo 'TAMA_ZFS_QUALIFIED_REVISION_UNAVAILABLE: Alpine v3.24 no longer provides "
    "linux-lts=6.18.55-r0 zfs=2.4.4-r0; refusing to substitute' >&2"
)


class StatusHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({'state': 'ready'}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class UnixServer(socketserver.UnixStreamServer):
    pass


class ZFSQualificationTests(unittest.TestCase):
    def test_diagnostic_version_text_does_not_count_as_install_line(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('prepare_zfs', PREPARE)
        prepare_zfs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(prepare_zfs)
        text = '\n'.join([INSTALL_LINE, DIAGNOSTIC, REBOOT_LINE, DIAGNOSTIC])
        self.assertTrue(prepare_zfs.qualification_bootstrap_ok(text))
        self.assertGreater(text.count('linux-lts=6.18.55-r0'), 1)
        self.assertFalse(prepare_zfs.qualification_bootstrap_ok(DIAGNOSTIC + '\n' + REBOOT_LINE))

    def test_qualification_seed_keeps_commands_top_level(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('prepare_zfs_seed', PREPARE)
        prepare_zfs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(prepare_zfs)
        init = prepare_zfs.qualification_init_script()
        self.assertTrue(init.startswith('#!/sbin/openrc-run\n'), init)
        self.assertIn('\ndescription="Disposable ZFS qualification bootstrap"\n', init)
        self.assertNotIn('\n    description=', init)
        emitted = prepare_zfs.qualification_user_data([
            ('/etc/init.d/tama-qualification', init),
            ('/usr/local/libexec/tama-bootstrap.sh', '#!/bin/sh\necho qualification\n'),
        ])
        lines = emitted.splitlines()
        boot = lines.index('bootcmd:')
        run = lines.index('runcmd:')
        self.assertGreater(run, boot)
        self.assertFalse(lines[boot].startswith(' '))
        self.assertFalse(lines[run].startswith(' '))
        self.assertTrue(lines[boot + 1].startswith('  - ['))
        self.assertTrue(lines[run + 1].startswith('  - ['))
        self.assertTrue(lines[run + 2].startswith('  - ['))
        block = emitted.split('  - path: /etc/init.d/tama-qualification', 1)[1]
        self.assertIn('\n      #!/sbin/openrc-run\n', block)
        self.assertIn('\n      description="Disposable ZFS qualification bootstrap"\n', block)
        self.assertNotIn('\n          description=', block)

    def test_guard_rejection_creates_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bootstrap = root / 'bootstrap.sh'
            bootstrap.write_text(DIAGNOSTIC + '\n' + 'linux-lts=6.18.55-r0\n' + REBOOT_LINE + '\n')
            output = Path(__file__).resolve().parents[2] / '.integration' / 'z-guard-no-output'
            output.rmdir() if output.exists() and not any(output.iterdir()) else None
            if output.exists():
                self.skipTest('pre-existing guard output directory')
            result = subprocess.run(
                [sys.executable, str(PREPARE), '--root-disk', str(root / 'missing.raw'),
                 '--output', str(output)],
                env={**os.environ, 'TAMA_QUALIFICATION_BOOTSTRAP': str(bootstrap)},
                text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('one qualified kernel/ZFS install line', result.stderr + result.stdout)
            self.assertFalse(output.exists())

    def fixture(self, directory, layout='qualification-v1', size=4, driver='dir', source='tama-data/workloads'):
        root = Path(directory)
        state = root / 'state'
        state.mkdir()
        appliance = root / 'appliance'
        appliance.mkdir()
        manifest = appliance / 'manifest.json'
        manifest.write_text('{}')
        (appliance / 'qualification.json').write_text(json.dumps({'layout': layout}))
        (state / 'config.json').write_text(json.dumps({
            'appliance_manifest_path': str(manifest), 'data_disk_gib': size,
        }))
        calls = root / 'calls.jsonl'
        incus = root / 'incus'
        incus.write_text('#!' + sys.executable + '\n' + '''import json, os, sys
with open(os.environ['QUALIFICATION_TEST_CALLS'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1] == 'query' and sys.argv[2] == '/1.0':
    print('{"environment":{"os_name":"Alpine"}}')
elif sys.argv[1] == 'query' and 'profiles' in sys.argv[2]:
    print('{"devices":{"root":{"pool":"default"}}}')
elif sys.argv[1] == 'query':
    print(os.environ['QUALIFICATION_TEST_POOL'])
''')
        incus.chmod(0o755)
        report = root / 'report.json'
        command = [sys.executable, str(RUNNER), '--hardware-opt-in', '--state-dir', str(state),
                   '--incus', str(incus), '--report', str(report)]
        env = dict(os.environ, QUALIFICATION_TEST_CALLS=str(calls),
                   QUALIFICATION_TEST_POOL=json.dumps({'driver': driver, 'config': {'source': source}}))
        return state, calls, report, command, env

    def test_wrong_driver_cannot_pass_or_launch_workloads(self):
        with tempfile.TemporaryDirectory() as directory:
            state, calls, report, command, env = self.fixture(directory)
            with UnixServer(str(state / 'runtime.sock'), StatusHandler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
                finally:
                    server.shutdown()
                    thread.join()
            self.assertNotEqual(result.returncode, 0)
            failed = json.loads(report.read_text())
            self.assertEqual(failed['status'], 'failed')
            self.assertIn('dir', failed['error'])
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertFalse(any(args[0] in ('launch', 'exec', 'storage') for args in commands))

    def test_whole_parent_pool_source_cannot_launch_workloads(self):
        with tempfile.TemporaryDirectory() as directory:
            state, calls, report, command, env = self.fixture(directory, driver='zfs', source='tama-data')
            with UnixServer(str(state / 'runtime.sock'), StatusHandler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    result = subprocess.run(command, env=env, capture_output=True, timeout=10)
                finally:
                    server.shutdown()
                    thread.join()
            self.assertNotEqual(result.returncode, 0)
            failed = json.loads(report.read_text())
            self.assertEqual(failed['status'], 'failed')
            self.assertIn('tama-data', failed['error'])
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertFalse(any(args[0] in ('launch', 'exec', 'storage') for args in commands))

    def test_valid_zfs_source_passes_storage_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            state, calls, report, command, env = self.fixture(
                directory, driver='zfs', source='tama-data/workloads')
            with UnixServer(str(state / 'runtime.sock'), StatusHandler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
                finally:
                    server.shutdown()
                    thread.join()
            self.assertNotEqual(result.returncode, 0)
            recorded = json.loads(report.read_text())
            self.assertIn('zfs_default_and_profile', recorded['checks'])
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertTrue(any(args[0] == 'launch' for args in commands))

    def test_foreign_layout_rejected_before_connecting(self):
        with tempfile.TemporaryDirectory() as directory:
            _, calls, _, command, env = self.fixture(directory, layout='production')
            result = subprocess.run(command, env=env, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(calls.exists())

    def test_exhaustion_rejects_large_disk_before_connecting(self):
        with tempfile.TemporaryDirectory() as directory:
            _, calls, _, command, env = self.fixture(directory, size=32)
            result = subprocess.run(command + ['--space-exhaustion'], env=env,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(calls.exists())

    def test_report_cannot_overwrite_runtime_data(self):
        with tempfile.TemporaryDirectory() as directory:
            state, calls, _, command, env = self.fixture(directory)
            disk = state / 'data.raw'
            disk.write_bytes(b'preserve-existing-data')
            command[-1] = str(disk)
            result = subprocess.run(command, env=env, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(calls.exists())
            self.assertEqual(disk.read_bytes(), b'preserve-existing-data')


if __name__ == '__main__':
    unittest.main()
