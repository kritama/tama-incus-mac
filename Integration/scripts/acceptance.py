#!/usr/bin/env python3
"""Opt-in real VZ/Incus acceptance. Uses the standard Incus CLI, never a VM CLI."""
import argparse
from datetime import datetime, timezone
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--state-dir', type=Path, required=True)
parser.add_argument('--incus', type=Path, required=True)
parser.add_argument('--report', type=Path, required=True)
args = parser.parse_args()
state = args.state_dir.resolve(strict=True)
incus = args.incus.resolve(strict=True)
report = {'schema_version': 1, 'started_at': datetime.now(timezone.utc).isoformat(),
          'scope': 'Alpine/Incus readiness, workload boot/exec/network, persistence, storage growth, read-only/writable VirtioFS and conditional nested VM',
          'checks': {}, 'commands': []}
name = 'tama-test-' + uuid.uuid4().hex[:10]
client = state / 'acceptance-client' / name
client.mkdir(parents=True, mode=0o700)
env = dict(os.environ, INCUS_CONF=str(client))
instances = [name, name + '-oci', name + '-oci-reuse', name + '-vm', name + '-shares']
oci_remote = name + '-remote'
# Versioned upstream tag keeps acceptance independent of moving "latest".
oci_image = oci_remote + ':alpine:3.23'
report['oci_image'] = 'docker.io/library/alpine:3.23'
share_files = []


def control(method, path, body=None):
    connection = http.client.HTTPConnection('localhost', timeout=1900)
    connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.sock.settimeout(1900)
    connection.sock.connect(str(state / 'runtime.sock'))
    try:
        connection.request(method, '/v1/runtime' + path, None if body is None else json.dumps(body), {'Content-Type': 'application/json'})
        response = connection.getresponse()
        value = json.loads(response.read())
        if response.status != 200:
            raise RuntimeError(value)
        return value
    finally:
        connection.close()


def run(*command, timeout=600):
    result = subprocess.run([str(incus), *command], env=env, text=True, capture_output=True, timeout=timeout)
    report['commands'].append({'arguments': list(command), 'exit_code': result.returncode,
                               'stdout': result.stdout[-16000:], 'stderr': result.stderr[-16000:]})
    save()
    if result.returncode:
        raise RuntimeError(f'Incus {command} failed: {result.stderr}')
    return result.stdout


def save():
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')


def check(key, value=True):
    report['checks'][key] = value
    save()
    print(f'{key}: {value}', flush=True)


def persistent_marker(expected):
    # Incus autostart may trail server readiness by a few seconds.
    for attempt in range(60):
        try:
            result = run('exec', name, '--', 'cat', '/root/tama-persistence', timeout=15)
        except (subprocess.TimeoutExpired, RuntimeError):
            time.sleep(1)
            continue
        assert result == expected, 'Container persistence marker changed'
        return
    raise RuntimeError('Persistent container did not return after outer restart')


try:
    status = control('GET', '/status')
    assert status['state'] == 'ready', status
    capabilities = control('GET', '/capabilities')
    report['capabilities'] = capabilities
    configuration = control('GET', '/config')
    shares = configuration['shares']
    assert any(s.get('read_only', True) for s in shares), 'Configure a dedicated read-only share fixture'
    assert any(not s.get('read_only', True) for s in shares), 'Configure a dedicated writable share fixture'
    check('linux_incus_ready')
    # macOS clients have no implicit "local" remote. Register the Unix relay
    # using the standard client, in an isolated per-run configuration.
    run('remote', 'add', 'native', 'unix:' + str(state / 'incus.sock'))
    run('remote', 'switch', 'native')
    run('info')
    server = json.loads(run('query', '/1.0'))
    report['server_environment'] = server['environment']
    assert 'alpine' in server['environment']['os_name'].lower(), server['environment']
    check('alpine_guest')
    check('standard_client_unix_vsock')
    run('launch', 'images:debian/13', name, '-c', 'boot.autostart=true')
    marker = uuid.uuid4().hex
    run('exec', name, '--', 'sh', '-c', f'printf {marker} > /root/tama-persistence; uname -m')
    check('system_container_exec_websocket')
    # exec is a standard Incus WebSocket operation; no custom execution endpoint exists.
    run('exec', name, '--', 'sh', '-c', 'for i in 1 2 3 4 5; do ping -c 1 -W 3 1.1.1.1 && exit 0; sleep 1; done; exit 1')
    check('container_outbound_network')
    assert capabilities['capabilities']['oci'], capabilities
    run('remote', 'add', oci_remote, 'https://docker.io', '--protocol=oci')
    run('launch', oci_image, name + '-oci', '-c', 'oci.entrypoint=sleep 3600')
    assert 'Linux' in run('exec', name + '-oci', '--', 'uname', '-s')
    check('oci_workload_exec_websocket')
    oci_instance = json.loads(run('query', '/1.0/instances/' + name + '-oci'))
    oci_fingerprint = oci_instance['config']['volatile.base_image']
    report['oci_fingerprint'] = oci_fingerprint
    run('image', 'export', oci_fingerprint, str(client / 'oci-cache-before-restart'))
    check('oci_cached_artifact_before_restart')
    control('POST', '/restart')
    persistent_marker(marker)
    check('outer_restart_persistence')
    configuration = control('GET', '/config')
    old_size = configuration['data_disk_gib']
    profile = json.loads(run('query', '/1.0/profiles/default'))
    pool = profile['devices']['root']['pool']
    resources_path = '/1.0/storage-pools/' + pool + '/resources'
    old_capacity = json.loads(run('query', resources_path))['space']['total']
    control('POST', '/stop')
    configuration['data_disk_gib'] = old_size + 1
    control('PUT', '/config', configuration)
    assert (state / 'runtime/data.raw').stat().st_size == (old_size + 1) * 1024 ** 3
    check('host_data_disk_growth')
    control('POST', '/start')
    new_capacity = json.loads(run('query', resources_path))['space']['total']
    assert new_capacity - old_capacity >= int(0.9 * 1024 ** 3), (old_capacity, new_capacity)
    check('guest_storage_capacity_growth', {'pool': pool, 'before_bytes': old_capacity, 'after_bytes': new_capacity})
    persistent_marker(marker)
    check('growth_preserves_instance_data')
    check('offline_data_disk_growth')
    # A separate privileged container tests the VZ share permissions themselves,
    # independently of unprivileged-container UID mapping. The main test remains
    # an ordinary unprivileged system container.
    share_instance = name + '-shares'
    run('launch', 'images:alpine/3.24', share_instance, '-c', 'security.privileged=true')
    for index, share in enumerate(shares):
        host_file = Path(share['path']) / ('.tama-share-' + uuid.uuid4().hex)
        token = uuid.uuid4().hex
        with host_file.open('x') as stream:
            stream.write(token)
        host_file.chmod(0o666)
        share_files.append(host_file)
        mount = '/mnt/tama-test-share-' + str(index)
        run('config', 'device', 'add', share_instance, 'share-' + str(index), 'disk',
            'source=/mnt/tama-shares/' + share['name'], 'path=' + mount, 'readonly=false')
        guest_file = mount + '/' + host_file.name
        assert run('exec', share_instance, '--', 'cat', guest_file) == token
        if share.get('read_only', True):
            assert run('exec', share_instance, '--', 'sh', '-c',
                       f'if printf changed > {guest_file}; then exit 1; fi; cat {guest_file}') == token
            # Apple's read-only directory export can reject writes with EACCES,
            # even when the Linux mount itself is writable. Both are valid.
            rejection = report['commands'][-1]['stderr'].lower()
            assert 'read-only' in rejection or 'permission denied' in rejection, report['commands'][-1]
            assert host_file.read_text() == token
            check('virtiofs_readonly_' + share['name'])
        else:
            changed = uuid.uuid4().hex
            assert run('exec', share_instance, '--', 'sh', '-c',
                       f'printf {changed} > {guest_file}; cat {guest_file}') == changed
            assert host_file.read_text() == changed
            check('virtiofs_writable_' + share['name'])
    check('virtiofs_shares')
    capabilities = control('GET', '/capabilities')
    if capabilities['capabilities']['vm']:
        run('launch', 'images:debian/13', name + '-vm', '--vm', '-c', 'limits.cpu=2', '-c', 'limits.memory=1GiB', '-c', 'security.secureboot=false')
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                result = subprocess.run([str(incus), 'exec', name + '-vm', '--', 'uname', '-m'], env=env, capture_output=True, text=True, timeout=20)
            except subprocess.TimeoutExpired:
                time.sleep(2)
                continue
            if result.returncode == 0:
                assert 'aarch64' in result.stdout
                report['commands'].append({'arguments': ['exec', name + '-vm', '--', 'uname', '-m'],
                                           'exit_code': 0, 'stdout': result.stdout, 'stderr': result.stderr})
                check('nested_vm_guest_agent_exec')
                break
            time.sleep(2)
        else:
            raise RuntimeError('Nested VM guest agent did not become ready')
    else:
        assert not (capabilities['capabilities']['nested_virtualization'] and
                    configuration['nested_virtualization']), 'Host nesting is supported/enabled but guest KVM/Incus VM support is missing'
        check('nested_vm_guest_agent_exec', 'unsupported: live host/guest nesting capability false')
    run('launch', oci_image, name + '-oci-reuse', '-c', 'oci.entrypoint=sleep 3600')
    assert 'Linux' in run('exec', name + '-oci-reuse', '--', 'uname', '-s')
    check('cached_oci_image_reuse_after_restart')
    for instance in instances:
        if instance.endswith('-vm') and not capabilities['capabilities']['vm']:
            continue
        run('delete', instance, '--force')
    run('remote', 'remove', oci_remote)
    report['status'] = 'passed'
except Exception as error:
    report['status'] = 'failed'
    report['error'] = str(error)
    report['retained_instances'] = instances
    report['retained_oci_remote'] = oci_remote
    raise
finally:
    for path in share_files:
        path.unlink(missing_ok=True)
    report['finished_at'] = datetime.now(timezone.utc).isoformat()
    save()
