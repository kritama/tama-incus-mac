#!/usr/bin/env python3
"""Signed CLI presentation acceptance. Fixture sockets only; never starts a VM."""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import threading
import time


class RuntimeFixture:
    def __init__(self, root):
        self.root = root
        self.state = 'ready'
        self.mode = 'success'
        self.calls = []
        self.dispatched = threading.Event()
        self.stop = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(root / 'runtime.sock'))
        os.chmod(root / 'runtime.sock', 0o600)
        self.listener.listen(16)
        self.listener.settimeout(0.1)
        self.incus = socket.socket(socket.AF_UNIX)
        self.incus.bind(str(root / 'incus.sock'))
        os.chmod(root / 'incus.sock', 0o600)
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.stop.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self.respond, args=(client,), daemon=True).start()

    def respond(self, client):
        with client:
            client.settimeout(3)
            data = b''
            while b'\r\n\r\n' not in data:
                chunk = client.recv(4096)
                if not chunk:
                    return
                data += chunk
            head, body = data.split(b'\r\n\r\n', 1)
            method, path, _ = head.split(b'\r\n', 1)[0].decode().split()
            length = next((int(line.split(b':', 1)[1]) for line in head.split(b'\r\n')
                           if line.lower().startswith(b'content-length:')), 0)
            while len(body) < length:
                body += client.recv(4096)
            self.calls.append([method, path])
            status = 200
            if method == 'POST':
                assert path == '/v1/runtime/start', (method, path)
                self.dispatched.set()
                mode = self.mode
                if mode in ('timeout', 'cancellation'):
                    self.stop.wait(10 if mode == 'timeout' else 3)
                else:
                    time.sleep(0.4)
                if mode == 'error':
                    status, obj = 500, {'error': {'code': 'io', 'message': 'Fixture boot failed; disks preserved'}}
                elif mode == 'timeout':
                    status, obj = 504, {'error': {'code': 'timeout', 'message': 'Fixture runtime wait exceeded deadline'}}
                else:
                    self.state = 'ready'
                    obj = self.status()
            elif path.endswith('/capabilities'):
                obj = {'platform': 'darwin', 'architecture': 'arm64', 'virtualization': 'apple-vz',
                       'supported': True, 'incus': {'available': True, 'version': 'fixture'},
                       'capabilities': {'system_containers': True, 'oci': True, 'vm': False,
                                        'nested_virtualization': True, 'virtiofs': True}}
            elif path.endswith('/health'):
                obj = {'protocol_version': 1, 'incus_version': 'fixture', 'kvm': False, 'api_extensions': ['instance_oci']}
            elif path.endswith('/progress'):
                obj = {'api_version': 1, 'state': self.state, 'ready': self.state == 'ready',
                       'phase': 'packages', 'expected_reboot': True, 'elapsed_seconds': 2}
            else:
                obj = self.status()
            payload = json.dumps(obj).encode()
            reply = f'HTTP/1.1 {status} OK\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n'.encode() + payload
            try:
                client.sendall(reply)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def status(self):
        return {'api_version': 1, 'state': self.state, 'incus_socket': str(self.root / 'incus.sock'),
                'uptime_seconds': 72, 'last_error': None}

    def close(self):
        self.stop.set()
        self.listener.close()
        self.incus.close()
        self.thread.join(2)


def invoke(binary, arguments, env, interactive=False, interrupt=None):
    if not interactive:
        result = subprocess.run([str(binary), *arguments], env=env, capture_output=True, text=True, timeout=15)
        return result.returncode, result.stdout, result.stderr
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 120, 0, 0))
    process = subprocess.Popen([str(binary), *arguments], env=env, stdout=slave, stderr=slave)
    os.close(slave)
    capture = bytearray()
    deadline = time.monotonic() + 15
    sent = False
    try:
        while time.monotonic() < deadline:
            if interrupt and interrupt.is_set() and not sent:
                process.send_signal(signal.SIGINT)
                sent = True
            if select.select([master], [], [], 0.05)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                capture.extend(chunk)
            elif process.poll() is not None:
                break
        code = process.wait(timeout=3)
        return code, capture.decode(), ''
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


def verify_startup(binary, client, env, fixture, report, host_supported):
    if not host_supported:
        report['startup_fixture_mode'] = 'unsupported-host rejection'
        for interactive in [False, True]:
            code, out, err = invoke(binary, ['start', '--incus', str(client)], env, interactive)
            assert code == 1, (code, out, err)
            assert 'Apple virtualization is unavailable' in out + err, (out, err)
            assert 'Macus is ready' not in out + err, (out, err)
            if interactive:
                failure = out.index('Macus failed')
                assert out.rindex('\x1b[?25h') < failure and '\x1b' not in out[failure:]
            else:
                assert not out and '\x1b' not in err, (out, err)
            report['transcripts'][('pty ' if interactive else 'redirected ') + 'start unsupported host'] = out + err
        code, out, err = invoke(binary, ['start', '--incus', str(client), '--json', '--progress', 'none'], env)
        assert code == 1 and not out and json.loads(err)['error']['code'] == 'unavailable', (code, out, err)
        assert all(method == 'GET' for method, _ in fixture.calls), fixture.calls
        assert not (fixture.root / 'bootstrap.lock').exists()
        report['transcripts']['redirected start unsupported host --json'] = err
        return
    report['startup_fixture_mode'] = 'supported-host runtime fixtures'
    for interactive in [False, True]:
        fixture.state, fixture.mode = 'ready', 'success'
        code, out, err = invoke(binary, ['start', '--incus', str(client)], env, interactive)
        assert code == 0, (out, err)
        summary = out.index('Macus is ready\r\n' if interactive else 'Macus is ready\n')
        if interactive:
            restored = out.rindex('\x1b[?25h')
            # The stage confirmation precedes the separate stdout heading.
            heading = out.index('Macus is ready\r\n', summary + 1)
            assert restored < heading and '\x1b' not in out[heading:]
        else:
            assert '\x1b' not in out + err and out.startswith('Macus is ready\n')
        report['transcripts'][('pty ' if interactive else 'redirected ') + 'start'] = out + err
    code, out, err = invoke(binary, ['start', '--incus', str(client), '--json', '--progress', 'none'], env)
    assert code == 0 and json.loads(out)['ready'] and json.loads(out)['connected'] and not err
    report['transcripts']['redirected start --json --progress none'] = out
    for mode, expected in [('error', 1), ('timeout', 1), ('cancellation', 130)]:
        fixture.state, fixture.mode = 'stopped', mode
        fixture.dispatched.clear()
        command = ['start', '--incus', str(client), '--timeout', '5' if mode == 'timeout' else '10']
        code, out, err = invoke(binary, command, env, True,
                                fixture.dispatched if mode == 'cancellation' else None)
        assert code == expected, (mode, code, out, err)
        assert fixture.dispatched.is_set(), (mode, 'runtime start was never dispatched', out, err)
        if mode == 'timeout':
            assert 'Macus failed (timeout)' in out, out
        report.setdefault('runtime_wait_cases', []).append({'mode': mode, 'dispatched': True, 'exit_status': code})
        failure = out.index('Macus failed')
        assert out.rindex('\x1b[?25h') < failure and '\x1b' not in out[failure:]
        assert 'runtime status' in out and 'runtime stop' in out
        report['transcripts']['pty start ' + mode] = out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
    report = {'kind': 'presentation-fixtures', 'hardware_acceptance': False, 'vm_booted': False, 'transcripts': {}}
    with tempfile.TemporaryDirectory(prefix='macus-present-', dir='/private/tmp') as temporary:
        root = Path(temporary)
        state = root / 'state'
        state.mkdir(mode=0o700)
        (state / 'runtime').mkdir()
        for name in ['root.raw', 'data.raw']:
            (state / 'runtime' / name).write_text('disk-sentinel')
        (state / 'config.json').write_text(json.dumps({'appliance_manifest_path': str(root / 'manifest.json')}))
        client = root / 'incus fixture'
        client.write_text('#!/bin/sh\ncase "$*" in\n"remote list --format json") echo "{}";;\n"remote get-default") echo local;;\n*) exit 0;;\nesac\n')
        client.chmod(0o700)
        config_before = (state / 'config.json').read_bytes()
        env = dict(os.environ, TERM='xterm-256color', NO_COLOR='', MACUS_STATE_DIR=str(state), MACUS_BREW_FALLBACK='0')
        env.pop('TIM_STATE_DIR', None)
        fixture = RuntimeFixture(state)
        try:
            host_supported = None
            for interactive in [False, True]:
                for command in [['--help'], ['capabilities'], ['capabilities', '--json'], ['--json', 'capabilities'],
                                ['runtime', 'status'], ['doctor'], ['doctor', '--json']]:
                    code, out, err = invoke(binary, command, env, interactive)
                    assert code == 0, (command, code, out, err)
                    assert '\x1b' not in out + err, (command, out, err)
                    if '--json' in command:
                        obj = json.loads(out)
                        if 'capabilities' in command:
                            assert type(obj['supported']) is bool
                            host_supported = obj['supported']
                            assert set(obj) == {'platform', 'architecture', 'virtualization', 'supported', 'nested_virtualization', 'virtiofs'}
                    report['transcripts'][('pty ' if interactive else 'redirected ') + ' '.join(command)] = out + err
            assert all(method == 'GET' for method, _ in fixture.calls)
            assert not (state / 'bootstrap.lock').exists()
            for flag in [['--timeout', '1'], ['--remote', 'demo'], ['--force']]:
                assert invoke(binary, ['capabilities', *flag], env)[0] == 2
            verify_startup(binary, client, env, fixture, report, host_supported)
            assert (state / 'config.json').read_bytes() == config_before
            assert all((state / 'runtime' / name).read_text() == 'disk-sentinel' for name in ['root.raw', 'data.raw'])
            assert not (state / 'appliance-cache').exists()
            report['requests'] = fixture.calls
        finally:
            fixture.close()
        # Foreground notice after actual socket bind; an absent runtime is never booted.
        serve_state = root / 'serve'
        log = root / 'serve-output'
        with log.open('w') as output:
            process = subprocess.Popen([str(binary), 'serve', '--state-dir', str(serve_state)], env=env, stdout=output, stderr=output)
            try:
                for _ in range(100):
                    if 'Macus is listening' in log.read_text():
                        break
                    time.sleep(0.02)
                assert (serve_state / 'runtime.sock').exists()
                assert 'foreground daemon' in log.read_text()
                process.send_signal(signal.SIGTERM)
                assert process.wait(timeout=5) == 0
                assert not (serve_state / 'runtime').exists()
                report['transcripts']['redirected serve'] = log.read_text()
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        report = json.loads(json.dumps(report).replace(temporary, '/tmp/macus-presentation-fixture'))
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Presentation acceptance passed: {len(report['transcripts'])} signed CLI transcripts; {report['startup_fixture_mode']}; no VM booted")


if __name__ == '__main__':
    main()
