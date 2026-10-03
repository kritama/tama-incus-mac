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
          'scope': 'Incus workload boot, exec, outbound network, restart persistence, storage growth and conditional nested VM; VirtioFS shares are not covered',
          'checks': {}, 'commands': []}
env = dict(os.environ, INCUS_SOCKET=str(state / 'incus.sock'), INCUS_CONF=str(state / 'acceptance-client'))
name = 'tama-test-' + uuid.uuid4().hex[:10]
instances = [name, name + '-oci', name + '-vm']
oci_remote = name + '-remote'


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


try:
    status = control('GET', '/status')
    assert status['state'] == 'ready', status
    capabilities = control('GET', '/capabilities')
    report['capabilities'] = capabilities
    check('linux_incus_ready')
    run('info')
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
    run('launch', oci_remote + ':alpine:latest', name + '-oci', '-c', 'oci.entrypoint=sleep 3600')
    assert 'Linux' in run('exec', name + '-oci', '--', 'uname', '-s')
    check('oci_workload_exec_websocket')
    control('POST', '/restart')
    # Incus autostart may trail server readiness by a few seconds.
    for attempt in range(60):
        try:
            result = subprocess.run([str(incus), 'exec', name, '--', 'cat', '/root/tama-persistence'], env=env, text=True, capture_output=True, timeout=15)
        except subprocess.TimeoutExpired:
            time.sleep(1)
            continue
        if result.returncode == 0:
            assert result.stdout == marker
            break
        time.sleep(1)
    else:
        raise RuntimeError('Persistent container did not return after outer restart')
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
    check('offline_data_disk_growth')
    check('virtiofs_shares', 'not covered by this runner; requires separate configured-share acceptance')
    capabilities = control('GET', '/capabilities')
    if capabilities['capabilities']['vm']:
        run('launch', 'images:debian/13', name + '-vm', '--vm', '-c', 'limits.cpu=2', '-c', 'limits.memory=1GiB')
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                result = subprocess.run([str(incus), 'exec', name + '-vm', '--', 'uname', '-m'], env=env, capture_output=True, text=True, timeout=20)
            except subprocess.TimeoutExpired:
                time.sleep(2)
                continue
            if result.returncode == 0:
                assert 'aarch64' in result.stdout
                check('nested_vm_guest_agent_exec')
                break
            time.sleep(2)
        else:
            raise RuntimeError('Nested VM guest agent did not become ready')
    else:
        check('nested_vm_guest_agent_exec', 'unsupported: live host/guest nesting capability false')
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
    report['finished_at'] = datetime.now(timezone.utc).isoformat()
    save()
