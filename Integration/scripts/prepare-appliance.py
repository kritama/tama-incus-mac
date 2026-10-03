#!/usr/bin/env python3
"""Prepare a verified raw image manifest and NoCloud ISO; does not run a VM."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--root-disk', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--appliance-id', default='debian-13-incus-v1')
args = parser.parse_args()
root = args.root_disk.resolve(strict=True)
if root.is_symlink() or not root.is_file():
    parser.error('root disk must be a regular raw file')
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True, mode=0o700)
# Manifest points to an image in its own directory: hard-link input or use input directory.
image = output / 'root.raw'
if not image.exists():
    try:
        image.hardlink_to(root)
    except OSError as error:
        parser.error(f'Cannot hard-link raw image into output directory: {error}. Put output on the same volume as the source.')
elif image.stat().st_ino != root.stat().st_ino:
    parser.error('output root.raw already refers to a different input')
with image.open('rb') as stream:
    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
manifest = {'schema_version': 1, 'id': args.appliance_id, 'architecture': 'arm64',
            'root_disk': 'root.raw', 'sha256': digest, 'vsock_protocol': 1}
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
source = Path(__file__).resolve().parents[1] / 'guest'
seed = output / 'seed'
seed.mkdir(exist_ok=True)
(seed / 'meta-data').write_text(f'instance-id: {args.appliance_id}\nlocal-hostname: tama-incus\n')
entries = [('bridge.py', '/usr/local/libexec/tama-bridge.py', '0755'),
           ('storage.sh', '/usr/local/libexec/tama-storage.sh', '0755'),
           ('bootstrap.sh', '/usr/local/libexec/tama-bootstrap.sh', '0755'),
           ('tama-storage.service', '/etc/systemd/system/tama-storage.service', '0644'),
           ('tama-bridge.service', '/etc/systemd/system/tama-bridge.service', '0644')]
# JSON strings are YAML-compatible scalars; use block contents without a YAML dependency.
user_data = '#cloud-config\noutput: {all: \"| tee -a /var/log/cloud-init-output.log /dev/hvc0\"}\nusers: []\nssh_pwauth: false\ndisable_root: true\nwrite_files:\n'
for filename, destination, permissions in entries:
    user_data += f'  - path: {destination}\n    permissions: "{permissions}"\n    content: |\n'
    user_data += ''.join('      ' + line + '\n' for line in (source / filename).read_text().splitlines())
user_data += 'runcmd:\n  - [bash, /usr/local/libexec/tama-bootstrap.sh]\n'
(seed / 'user-data').write_text(user_data)
subprocess.run(['/usr/bin/hdiutil', 'makehybrid', '-iso', '-joliet', '-default-volume-name', 'cidata',
                '-o', str(output / 'seed.iso'), str(seed)], check=True)
config = {'schema_version': 1, 'cpu_count': 4, 'memory_mib': 4096, 'data_disk_gib': 32,
          'appliance_manifest_path': str(output / 'manifest.json'), 'seed_path': str(output / 'seed.iso'),
          'nested_virtualization': True, 'shares': [], 'readiness_timeout_seconds': 600,
          'shutdown_timeout_seconds': 60}
(output / 'config.json').write_text(json.dumps(config, indent=2) + '\n')
print(output / 'config.json')
