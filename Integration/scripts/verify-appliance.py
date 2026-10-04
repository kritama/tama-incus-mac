#!/usr/bin/env python3
"""Verify Alpine's signed archive and safely extract its raw disk; no VM runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

FINGERPRINT = 'F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22'

parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--checksum-file', type=Path, required=True)
parser.add_argument('--signature', type=Path, required=True)
parser.add_argument('--signing-key', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
gpg = shutil.which('gpg')
if not gpg:
    parser.error('GnuPG is required for image preparation, not runtime operation')
expected = args.checksum_file.read_text().split()[0].lower()
if len(expected) != 128 or any(c not in '0123456789abcdef' for c in expected):
    parser.error('Expected a SHA-512 checksum')
with args.archive.open('rb') as stream:
    actual = hashlib.file_digest(stream, 'sha512').hexdigest()
if actual != expected:
    parser.error('Archive SHA-512 mismatch; no raw disk extracted')
# Isolate GnuPG from the user's keyring and private keys. Pin the published cloud key.
with tempfile.TemporaryDirectory(prefix='tama-alpine-gpg-') as home:
    command = [gpg, '--homedir', home, '--batch', '--no-autostart']
    subprocess.run(command + ['--import', str(args.signing_key.resolve(strict=True))],
                   check=True, capture_output=True, text=True)
    result = subprocess.run(command + ['--status-fd', '1', '--verify',
                            str(args.signature.resolve(strict=True)), str(args.archive.resolve(strict=True))],
                            capture_output=True, text=True)
    valid = any(line.startswith('[GNUPG:] VALIDSIG ') and
                (line.split()[2] == FINGERPRINT or line.split()[-1] == FINGERPRINT)
                for line in result.stdout.splitlines())
    if result.returncode or not valid:
        parser.error('Archive signature does not match the pinned Alpine cloud signing key')
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True, mode=0o700)
target = output / 'disk.raw'
if target.is_symlink() or (target.exists() and not target.is_file()):
    parser.error('Existing raw output is not a regular file')
staged = None
try:
    with tarfile.open(args.archive, 'r:gz') as archive:
        members = archive.getmembers()
        if len(members) != 1 or members[0].name != 'disk.raw' or not members[0].isfile():
            parser.error('Expected exactly one regular disk.raw archive member')
        with tempfile.NamedTemporaryFile(dir=output, prefix='.disk-', delete=False) as stream:
            staged = Path(stream.name)
            with archive.extractfile(members[0]) as source:
                shutil.copyfileobj(source, stream, length=1024 * 1024)
            stream.flush()
            os.fsync(stream.fileno())
    with staged.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if target.exists():
        with target.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                parser.error('Existing output differs; choose a new directory')
    else:
        # Exclusive publication never replaces an existing image.
        target.hardlink_to(staged)
    provenance = {'archive': args.archive.name, 'archive_sha512': actual,
                  'signing_fingerprint': FINGERPRINT, 'raw_sha256': digest}
    (output / 'verification.json').write_text(json.dumps(provenance, indent=2) + '\n')
finally:
    if staged is not None:
        staged.unlink(missing_ok=True)
print(target)
