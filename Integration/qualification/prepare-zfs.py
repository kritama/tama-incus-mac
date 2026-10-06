#!/usr/bin/env python3
"""Prepare an isolated ZFS compatibility seed; does not boot or change production provisioning."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import textwrap

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root-disk', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--memory-mib', type=int, default=4096)
parser.add_argument('--data-disk-gib', type=int, default=32)
INSTALL_LINE = (
    '    linux-lts=6.18.55-r0 zfs=2.4.4-r0 zfs-libs=2.4.4-r0 '
    'zfs-lts=6.18.55-r0 zfs-openrc=2.4.4-r0; then'
)
REBOOT_LINE = '    echo TAMA_ZFS_KERNEL_REBOOT_REQUIRED'

def qualification_bootstrap_ok(text):
    """Count the install and reboot commands, not version substrings in diagnostics."""
    lines = text.splitlines()
    return lines.count(INSTALL_LINE) == 1 and lines.count(REBOOT_LINE) == 1

def qualification_init_script():
    return textwrap.dedent('''\
        #!/sbin/openrc-run
        description="Disposable ZFS qualification bootstrap"
        depend() {
            need networking
            after cloud-init
        }
        start() {
            /usr/local/libexec/tama-bootstrap.sh > /dev/hvc0 2>&1
        }
        ''')

def qualification_user_data(entries):
    """Cloud-config written into the qualification seed. bootcmd and runcmd stay top-level."""
    user_data = '#cloud-config\noutput: {all: "| tee -a /var/log/cloud-init-output.log /dev/hvc0"}\nusers: []\nssh_pwauth: false\ndisable_root: true\nwrite_files:\n'
    for destination, content in entries:
        user_data += f'  - path: {destination}\n    permissions: "0755"\n    content: |\n'
        user_data += ''.join('      ' + line + '\n' for line in content.splitlines())
    user_data += textwrap.dedent('''\
        bootcmd:
          - [sh, -c, "(sleep 30; uname -r; rc-status -a; df -h /boot; test ! -f /var/log/tama-storage.log || cat /var/log/tama-storage.log) > /dev/hvc0 2>&1 &"]
        runcmd:
          - [rc-update, add, tama-qualification, default]
          - [rc-service, tama-qualification, start]
        ''')
    return user_data

def main():
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    bootstrap_path = Path(os.environ['TAMA_QUALIFICATION_BOOTSTRAP']) if 'TAMA_QUALIFICATION_BOOTSTRAP' in os.environ else project / 'Integration/guest/bootstrap.sh'
    bootstrap = bootstrap_path.read_text()
    if not qualification_bootstrap_ok(bootstrap):
        raise SystemExit('production bootstrap must contain one qualified kernel/ZFS install line and reboot marker')
    if args.memory_mib < 2048 or args.data_disk_gib < 4:
        parser.error('Qualification requires at least 2048 MiB RAM and a 4 GiB data disk')
    if args.root_disk.is_symlink() or not (args.root_disk.parent / 'verification.json').is_file():
        parser.error('Use a nonsymlink raw image from verify-appliance.py')
    output = args.output.resolve()
    if not output.is_relative_to(project / '.integration') or output.exists():
        parser.error('Choose a new output directory inside this checkout\'s .integration')
    # Guard already passed. Only then may prepare-appliance create output.
    source = project / 'Integration/guest'
    subprocess.run([sys.executable, str(project / 'Integration/scripts/prepare-appliance.py'),
                    '--root-disk', str(args.root_disk.resolve(strict=True)), '--output', str(output),
                    '--appliance-id', 'alpine-3.24.2-zfs-qualification-v1'], check=True)
    # Reuse that block. Do not splice a second package install or reboot.
    bootstrap += '\nrc-update del tama-qualification default\n'
    init = qualification_init_script()
    storage_init = (source / 'tama-storage.initd').read_text().replace('    umount /var/lib/incus',
        '    zpool export tama-data > /var/log/tama-zfs-export.log 2>&1 && echo TAMA_ZFS_EXPORT_OK >> /var/log/tama-zfs-export.log')
    entries = [
        ('/usr/local/libexec/tama-bridge.py', (source / 'bridge.py').read_text()),
        ('/usr/local/libexec/tama-bootstrap.sh', bootstrap),
        ('/usr/local/libexec/tama-storage.sh', (Path(__file__).parent / 'zfs-storage.sh').read_text()),
        ('/etc/init.d/tama-storage', storage_init),
        ('/etc/init.d/tama-bridge', (source / 'tama-bridge.initd').read_text()),
        ('/etc/init.d/tama-qualification', init),
    ]
    user_data = qualification_user_data(entries)
    (output / 'seed/user-data').write_text(user_data)
    # Replace only the ISO just generated in this new qualification directory.
    (output / 'seed.iso').unlink()
    subprocess.run(['/usr/bin/hdiutil', 'makehybrid', '-iso', '-joliet', '-default-volume-name', 'cidata',
                    '-o', str(output / 'seed.iso'), str(output / 'seed')], check=True)
    config = json.loads((output / 'config.json').read_text())
    config['readiness_timeout_seconds'] = 180
    config['memory_mib'] = args.memory_mib
    config['data_disk_gib'] = args.data_disk_gib
    shares = output / 'shares'
    for name in ('readonly', 'writable'):
        path = shares / name
        path.mkdir(parents=True, mode=0o777)
        path.chmod(0o777)
        config['shares'].append({'name': name, 'path': str(path), 'read_only': name == 'readonly'})
    (output / 'config.json').write_text(json.dumps(config, indent=2) + '\n')
    (output / 'qualification.json').write_text(json.dumps({
        'scope': 'disposable ZFS compatibility fixture, not production provisioning',
        'layout': 'qualification-v1', 'packages': 'signed stable-branch snapshot recorded in guest',
        'metadata': 'tama-data/metadata', 'workloads': 'tama-data/workloads',
    }, indent=2) + '\n')
    print(output / 'config.json')


if __name__ == '__main__':
    main()
