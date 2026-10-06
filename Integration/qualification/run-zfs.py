#!/usr/bin/env python3
"""Opt-in ZFS compatibility evidence on an already ready disposable VZ appliance."""
import argparse
from datetime import datetime, timezone
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hardware-opt-in', action='store_true', required=True)
    parser.add_argument('--state-dir', type=Path, required=True)
    parser.add_argument('--incus', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--space-exhaustion', action='store_true',
                        help='Fill a disposable data disk configured at most 7 GiB before growth; preserve metadata headroom')
    args = parser.parse_args()
    state = args.state_dir.resolve(strict=True)
    configuration = json.loads((state / 'config.json').read_text())
    manifest = Path(configuration['appliance_manifest_path'])
    fixture = json.loads((manifest.parent / 'qualification.json').read_text())
    if fixture['layout'] != 'qualification-v1':
        parser.error('Refusing a non-qualification appliance')
    report_path = args.report.resolve()
    if report_path.is_relative_to(state) or report_path.is_relative_to(manifest.parent):
        parser.error('Report must be outside runtime state and appliance source directories')
    if args.space_exhaustion and (configuration['data_disk_gib'] > 7 or
                                 shutil.disk_usage(state).free < 12 * 1024 ** 3):
        parser.error('Space exhaustion requires a small disposable fixture and 12 GiB host headroom')
    client = state / ('zfs-client-' + uuid.uuid4().hex[:8])
    client.mkdir(mode=0o700)
    env = dict(os.environ, INCUS_CONF=str(client))
    incus = str(args.incus.resolve(strict=True))
    prefix = 'zq-' + uuid.uuid4().hex[:8]
    report = {'schema_version': 1, 'scope': 'ZFS compatibility spike, not production acceptance',
              'started_at': datetime.now(timezone.utc).isoformat(), 'fixture': fixture,
              'image': json.loads(manifest.read_text()), 'checks': {}, 'commands': [],
              'configuration': configuration, 'controls': [],
              'retained_prefix': prefix, 'state_dir': str(state)}

    def save():
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')

    def run(*command, expected=0, timeout=600):
        result = subprocess.run([incus, *command], env=env, capture_output=True,
                                text=True, timeout=timeout)
        report['commands'].append({'arguments': list(command), 'exit_code': result.returncode,
                                   'stdout': result.stdout[-20000:], 'stderr': result.stderr[-12000:]})
        save()
        if expected is not None and ((expected == 0 and result.returncode != 0) or
                                     (expected != 0 and result.returncode == 0)):
            raise RuntimeError(f'Unexpected result for {command}: {result.stderr}')
        return result.stdout

    def control(method, path, body=None):
        connection = http.client.HTTPConnection('localhost', timeout=650)
        connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.sock.settimeout(650)
        connection.sock.connect(str(state / 'runtime.sock'))
        try:
            connection.request(method, '/v1/runtime' + path,
                               None if body is None else json.dumps(body),
                               {'Content-Type': 'application/json'})
            response = connection.getresponse()
            value = json.loads(response.read())
            report['controls'].append({'method': method, 'path': path, 'body': body,
                                       'http_status': response.status, 'response': value})
            save()
            if response.status != 200:
                raise RuntimeError(value)
            return value
        finally:
            connection.close()

    def check(name, value=True):
        report['checks'][name] = value
        save()
        print(name, json.dumps(value), flush=True)

    def query(path):
        return json.loads(run('query', path))

    probe = prefix + '-probe'

    def guest(script):
        return run('exec', probe, '--', 'nsenter', '--mount=/hostproc/1/ns/mnt',
                   '--root=/hostproc/1/root', '--wd=/',
                   '/bin/sh', '-ec', script)

    def wait_instance(instance):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                value = subprocess.run([incus, 'exec', instance, '--', 'true'], env=env,
                                       capture_output=True, timeout=15)
            except subprocess.TimeoutExpired:
                continue
            if value.returncode == 0:
                return
            time.sleep(1)
        raise RuntimeError(f'{instance} did not return')

    try:
        assert control('GET', '/status')['state'] == 'ready'
        run('remote', 'add', 'native', 'unix:' + str(state / 'incus.sock'))
        run('remote', 'switch', 'native')
        pool = query('/1.0/storage-pools/default')
        assert pool['driver'] == 'zfs' and pool['config']['source'] == 'tama-data/workloads', pool
        assert query('/1.0/profiles/default')['devices']['root']['pool'] == 'default'
        check('zfs_default_and_profile', pool)
        report['server_environment'] = query('/1.0')['environment']
        run('launch', 'images:alpine/3.24', probe, '-c', 'security.privileged=true',
            '-c', 'security.nesting=true', '-c', 'boot.autostart=true')
        run('config', 'device', 'add', probe, 'hostproc', 'disk', 'source=/proc',
            'path=/hostproc', 'readonly=true')
        baseline = guest('uname -r; zfs version; zpool get -Hp -o property,value guid,size,allocated,free tama-data; zpool status -P; zfs list -o name,mountpoint,used,available; cat /var/log/tama-appliance-packages.txt; cat /proc/meminfo; cat /proc/spl/kstat/zfs/arcstats')
        check('kernel_module_layout_and_resources', baseline)
        assert guest('cat /sys/module/zfs/parameters/zfs_arc_max').strip() == '536870912'
        assert guest('zfs get -Hp -o value refreservation tama-data/metadata').strip() == str(1024 ** 3)
        check('bounded_arc_and_metadata_reservation')
        run('exec', probe, '--', 'sh', '-ec',
            'i=0; while [ "$i" -lt 30 ]; do ping -c 1 -W 3 1.1.1.1 && exit 0; i=$((i+1)); sleep 2; done; exit 1')
        check('container_outbound_network')
        for index, share in enumerate(configuration['shares']):
            host_file = Path(share['path']) / ('.zfs-qualification-' + uuid.uuid4().hex)
            token = uuid.uuid4().hex
            host_file.write_text(token)
            host_file.chmod(0o666)
            mount = '/mnt/qualification-share-' + str(index)
            try:
                run('config', 'device', 'add', probe, 'share-' + str(index), 'disk',
                    'source=/mnt/tama-shares/' + share['name'], 'path=' + mount, 'readonly=false')
                target = mount + '/' + host_file.name
                assert run('exec', probe, '--', 'cat', target) == token
                if share.get('read_only', True):
                    run('exec', probe, '--', 'sh', '-ec', f'printf changed > {target}', expected=1)
                    assert host_file.read_text() == token
                else:
                    run('exec', probe, '--', 'sh', '-ec', f'printf changed > {target}')
                    assert host_file.read_text() == 'changed'
                check('virtiofs_' + share['name'])
            finally:
                host_file.unlink(missing_ok=True)
        guid = guest('zpool get -H -o value guid tama-data').strip()
        marker = prefix + '-marker'
        run('exec', probe, '--', 'sh', '-ec', f'printf {marker} > /root/marker; sync')
        for snap, value in [('s1', marker), ('s2', marker + '-2'), ('s3', marker + '-3')]:
            run('exec', probe, '--', 'sh', '-ec', f'printf {value} > /root/marker; sync')
            run('snapshot', 'create', probe, snap)
        clone = prefix + '-clone'
        run('copy', probe + '/s3', clone)
        run('stop', probe)
        run('snapshot', 'restore', probe, 's1', expected=1)
        assert 'snapshot' in report['commands'][-1]['stderr'].lower(), report['commands'][-1]
        run('start', probe)
        assert run('exec', probe, '--', 'cat', '/root/marker') == marker + '-3'
        snapshot_names = [item['name'].split('/')[-1] for item in query('/1.0/instances/' + probe + '/snapshots?recursion=1')]
        assert set(snapshot_names) == {'s1', 's2', 's3'}, snapshot_names
        run('start', clone)
        assert run('exec', clone, '--', 'cat', '/root/marker') == marker + '-3'
        recovered = prefix + '-recovered'
        run('copy', probe + '/s1', recovered)
        run('start', recovered)
        assert run('exec', recovered, '--', 'cat', '/root/marker') == marker
        check('older_restore_refuses_without_deleting_descendants')
        check('copy_older_snapshot_preserves_newer_snapshots_and_clone')
        volume = prefix + '-volume'
        run('storage', 'volume', 'create', 'default', volume, 'size=128MiB')
        run('storage', 'volume', 'attach', 'default', volume, probe, 'qualification-volume', '/mnt/volume')
        run('exec', probe, '--', 'sh', '-ec', 'dd if=/dev/urandom of=/mnt/volume/data bs=1M count=32; sync')
        checksum = run('exec', probe, '--', 'sha256sum', '/mnt/volume/data')
        run('storage', 'volume', 'snapshot', 'create', 'default', volume, 's1')
        run('exec', probe, '--', 'sh', '-ec', 'dd if=/dev/urandom of=/mnt/volume/full bs=1M count=256; sync', expected=1)
        assert run('exec', probe, '--', 'sha256sum', '/mnt/volume/data') == checksum
        run('exec', probe, '--', 'rm', '/mnt/volume/full')
        check('custom_volume_quota_preserves_existing_data')
        capabilities = control('GET', '/capabilities')
        report['capabilities'] = capabilities
        vm = None
        if capabilities['capabilities']['vm']:
            vm = prefix + '-vm'
            run('launch', 'images:debian/13', vm, '--vm', '-c', 'limits.cpu=2',
                '-c', 'limits.memory=1GiB', '-c', 'security.secureboot=false', '-c', 'boot.autostart=true')
            wait_instance(vm)
            run('exec', vm, '--', 'sh', '-ec', 'dd if=/dev/urandom of=/root/zfs-proof bs=1M count=32; sync')
            vm_checksum = run('exec', vm, '--', 'sha256sum', '/root/zfs-proof')
            run('stop', vm)
            run('snapshot', 'create', vm, 's1')
            run('start', vm)
            wait_instance(vm)
            run('exec', vm, '--', 'sh', '-ec', 'dd if=/dev/urandom of=/root/zfs-proof bs=1M count=32; sync')
            run('stop', vm)
            run('snapshot', 'restore', vm, 's1')
            run('start', vm)
            wait_instance(vm)
            assert run('exec', vm, '--', 'sha256sum', '/root/zfs-proof') == vm_checksum
            check('nested_vm_random_overwrite_snapshot_restore')
            block = prefix + '-block'
            run('storage', 'volume', 'create', 'default', block, '--type=block', 'size=128MiB')
            run('stop', vm)
            run('storage', 'volume', 'attach', 'default', block, vm, 'qualification-block')
            run('start', vm)
            wait_instance(vm)
            device = run('exec', vm, '--', 'sh', '-ec',
                         "lsblk -bndo NAME,SIZE,TYPE | awk '$2==134217728 && $3==\"disk\" {print \"/dev/\"$1}'").strip()
            assert device.startswith('/dev/') and '\n' not in device, device
            run('exec', vm, '--', 'sh', '-ec', f'dd if=/dev/urandom of={device} bs=1M count=16; sync')
            block_checksum = run('exec', vm, '--', 'sh', '-ec', f'dd if={device} bs=1M count=16 | sha256sum')
            run('exec', vm, '--', 'sh', '-ec',
                f'dd if=/dev/urandom of={device} bs=1M seek=128 count=1; sync', expected=1)
            assert run('exec', vm, '--', 'sh', '-ec', f'dd if={device} bs=1M count=16 | sha256sum') == block_checksum
            check('nested_vm_block_volume_limit_preserves_data', {'bytes': 134217728, 'checksum': block_checksum.strip()})
            check('nested_vm_resource_sample', guest('cat /proc/meminfo; cat /proc/spl/kstat/zfs/arcstats'))
        else:
            check('nested_vm_random_overwrite_snapshot_restore', 'unsupported: guest KVM unavailable')
        capacity_path = '/1.0/storage-pools/default/resources'
        capacity = query(capacity_path)['space']['total']
        check('before_growth', {'capacity': capacity, 'guid': guid,
                               'host_allocated_bytes': (state / 'runtime/data.raw').stat().st_blocks * 512})
        control('POST', '/restart')
        wait_instance(probe)
        assert 'TAMA_ZFS_EXPORT_OK' in guest('cat /var/log/tama-zfs-export.log')
        assert guest('zpool get -H -o value guid tama-data').strip() == guid
        assert run('exec', probe, '--', 'sha256sum', '/mnt/volume/data') == checksum
        if vm:
            wait_instance(vm)
            assert run('exec', vm, '--', 'sha256sum', '/root/zfs-proof') == vm_checksum
        check('graceful_export_import_persistence')
        control('POST', '/stop', {'force': True})
        control('POST', '/start')
        wait_instance(probe)
        assert guest('zpool get -H -o value guid tama-data').strip() == guid
        assert run('exec', probe, '--', 'sha256sum', '/mnt/volume/data') == checksum
        if vm:
            wait_instance(vm)
            assert run('exec', vm, '--', 'sha256sum', '/root/zfs-proof') == vm_checksum
        check('forced_stop_import_persistence')
        control('POST', '/stop')
        config = control('GET', '/config')
        config['data_disk_gib'] += 1
        control('PUT', '/config', config)
        control('POST', '/start')
        wait_instance(probe)
        grown = query(capacity_path)['space']['total']
        assert grown > capacity + int(0.9 * 1024 ** 3), (capacity, grown)
        assert guest('zpool get -H -o value guid tama-data').strip() == guid
        assert run('exec', probe, '--', 'sha256sum', '/mnt/volume/data') == checksum
        if vm:
            wait_instance(vm)
            assert run('exec', vm, '--', 'sha256sum', '/root/zfs-proof') == vm_checksum
            check('nested_vm_data_survives_restarts_and_growth')
        check('stopped_growth_preserves_identity_and_data', {'before': capacity, 'after': grown})
        check('post_reboot_module_and_resources', guest('uname -r; zfs version; cat /proc/meminfo; cat /proc/spl/kstat/zfs/arcstats; zpool status -P'))
        for instance, value in [(probe, marker + '-3'), (clone, marker + '-3'), (recovered, marker)]:
            wait_instance(instance)
            assert run('exec', instance, '--', 'cat', '/root/marker') == value
        assert {item['name'].split('/')[-1] for item in query('/1.0/instances/' + probe + '/snapshots?recursion=1')} == {'s1', 's2', 's3'}
        check('snapshots_and_clones_survive_restarts_and_growth')
        if args.space_exhaustion:
            # Appliance-owned metadata headroom is a measured candidate policy.
            guest('zfs set refreservation=1G tama-data/metadata')
            full = prefix + '-full'
            run('storage', 'volume', 'create', 'default', full)
            full_config = query('/1.0/storage-pools/default/volumes/custom/' + full)
            assert not full_config['config'].get('size'), full_config
            run('storage', 'volume', 'attach', 'default', full, probe, 'full-volume', '/mnt/full')
            before = query(capacity_path)
            run('exec', probe, '--', 'sh', '-ec', 'dd if=/dev/urandom of=/mnt/full/fill bs=16M count=1024; sync', expected=1)
            assert 'no space left' in report['commands'][-1]['stderr'].lower(), report['commands'][-1]
            assert run('exec', probe, '--', 'sha256sum', '/mnt/volume/data') == checksum
            assert run('exec', recovered, '--', 'cat', '/root/marker') == marker
            during = query(capacity_path)
            allocation = (state / 'runtime/data.raw').stat().st_blocks * 512
            check('workload_pool_exhaustion_preserves_metadata_and_data', {
                'metadata_refreservation_bytes': 1024 ** 3, 'before': before,
                'during': during, 'host_allocated_bytes': allocation,
                'scope': 'physical workload space exhausted; metadata reservation and ZFS slop retained'})
            control('POST', '/restart')
            assert query('/1.0/storage-pools/default')['driver'] == 'zfs'
            assert {item['name'].split('/')[-1] for item in query('/1.0/instances/' + probe + '/snapshots?recursion=1')} == {'s1', 's2', 's3'}
            # Incus metadata/API may recover while a zero-free-space workload cannot start.
            run('start', probe, expected=None)
            start_result = report['commands'][-1]
            check('exhausted_pool_reboot_metadata_available', {
                'workload_start_exit_code': start_result['exit_code'],
                'workload_start_error': start_result['stderr'],
                'limitation': 'workload startup can require freeing space first'})
            # Standard Incus volume deletion works without a running privileged probe.
            run('storage', 'volume', 'detach', 'default', full, probe, 'full-volume', expected=None)
            detach_result = report['commands'][-1]
            assert not query('/1.0/storage-pools/default/volumes/custom/' + full)['used_by']
            check('full_pool_filler_detach', {
                'exit_code': detach_result['exit_code'], 'error': detach_result['stderr'],
                'verified_unattached': True})
            run('storage', 'volume', 'delete', 'default', full)
            if query('/1.0/instances/' + probe + '/state')['status'].lower() != 'running':
                run('start', probe)
            wait_instance(probe)
            assert guest('zpool get -H -o value guid tama-data').strip() == guid
            assert run('exec', probe, '--', 'sha256sum', '/mnt/volume/data') == checksum
            if vm:
                if query('/1.0/instances/' + vm + '/state')['status'].lower() != 'running':
                    run('start', vm)
                wait_instance(vm)
                assert run('exec', vm, '--', 'sha256sum', '/root/zfs-proof') == vm_checksum
            check('full_pool_recovery_preserves_identity_and_data')
            trim = guest('if zpool trim tama-data; then zpool wait -t trim tama-data; else echo TRIM_UNSUPPORTED; fi')
            check('deletion_and_trim', {'guest_resources': query(capacity_path), 'trim': trim,
                                       'host_allocated_bytes': (state / 'runtime/data.raw').stat().st_blocks * 512})
            assert run('exec', probe, '--', 'sha256sum', '/mnt/volume/data') == checksum
        if vm:
            run('config', 'set', vm, 'boot.autostart=false')
            run('stop', vm)
            check('successful_vm_fixture_stopped')
        report['status'] = 'passed'
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = str(error)
        raise
    finally:
        report['finished_at'] = datetime.now(timezone.utc).isoformat()
        save()


if __name__ == '__main__':
    main()
