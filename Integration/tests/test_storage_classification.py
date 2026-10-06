"""Guest storage classification must preserve every nonblank disk."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'guest/storage.sh'
STORAGE_TEXT = SCRIPT.read_text()


def write_stub(directory, name, body):
    path = directory / name
    path.write_text('#!/bin/sh\n' + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


class StorageClassificationTests(unittest.TestCase):
    def run_storage(self, root, disk, action='start', kind='', label='', memory='4008360', extra_env=None):
        bin_dir = root / 'bin'
        bin_dir.mkdir(exist_ok=True)
        calls = root / 'calls'
        write_stub(bin_dir, 'blkid', f'''
if [ "$2" = TYPE ]; then printf '%s\\n' '{kind}'; else printf '%s\\n' '{label}'; fi
''')
        write_stub(bin_dir, 'modprobe', f'''
printf "%s\\n" "$*" >> "{calls}"
if [ "${{TAMA_MODPROBE_FAIL:-}}" = zfs ] && [ "$1" = zfs ]; then exit 1; fi
''')
        write_stub(bin_dir, 'zpool', f'''
printf "zpool %s\\n" "$*" >> "{calls}"
if [ "$1" = get ]; then
  case "$*" in
    *expandsize*) printf '%s\\n' "${{TAMA_ZPOOL_EXPANDSIZE:--}}" ;;
    *size*) printf '4294967296\\n' ;;
    *) printf '120\\n' ;;
  esac
  exit 0
fi
if [ "$1" = status ]; then printf '%s\\n' "{disk}"; exit 0; fi
if [ "$1" = online ] && [ "${{TAMA_ZPOOL_ONLINE_FAIL:-}}" = 1 ]; then exit 1; fi
if [ "$1" = import ]; then
  if [ "${{TAMA_ZPOOL_IMPORT_OK:-}}" = 1 ]; then exit 0; fi
  exit 1
fi
exit 0
''')
        write_stub(bin_dir, 'zfs', f'''
printf "zfs %s\\n" "$*" >> "{calls}"
if [ "$1" = get ]; then
  case "$*" in
    *available*) printf '1073741824\\n' ;;
    *refreservation*) printf '1073741824\\n' ;;
    *mounted*) printf 'yes\\n' ;;
    *name*) printf 'tama-data/metadata\\n' ;;
    *) printf '%s\\n' "$TAMA_METADATA_MOUNT" ;;
  esac
  exit 0
fi
exit 0
''')
        for command in ('mount', 'umount', 'e2fsck', 'resize2fs', 'blockdev', 'mkfs.ext4'):
            write_stub(bin_dir, command, f'printf "%s %s\\n" "{command}" "$*" >> "{calls}"\n')
        write_stub(bin_dir, 'mountpoint', 'if [ "${TAMA_MOUNTPOINT_PRESENT:-}" = 1 ]; then exit 0; fi\nexit 1\n')
        write_stub(bin_dir, 'findmnt', 'printf "%s\\n" "${TAMA_FINDMOUNT_SOURCE:-tama-data/metadata}"\n')
        write_stub(bin_dir, 'sync', 'exit 0\n')
        write_stub(bin_dir, 'incus', f'''
printf "incus %s\\n" "$*" >> "{calls}"
if [ "$2" = /1.0/profiles/default ]; then
  printf '%s\\n' '{{"devices":{{"root":{{"pool":"default","size":"2GiB"}}}}}}'
else
  printf '%s\\n' '{{"driver":"zfs","config":{{"source":"tama-data/workloads","volume.zfs.reserve_space":"true","volume.zfs.use_refquota":"true"}}}}'
fi
''')
        env = dict(os.environ)
        env.update({
            'PATH': f'{bin_dir}:/usr/bin:/bin',
            'TAMA_STORAGE_ROOT': str(root),
            'TAMA_DISK': str(disk),
            'TAMA_METADATA_MOUNT': str(root / 'metadata'),
            'TAMA_MEMINFO': str(root / 'meminfo'),
            'TAMA_STORAGE_LOG': str(root / 'storage.log'),
        })
        if extra_env:
            env.update(extra_env)
        (root / 'meminfo').write_text(f'MemTotal:       {memory} kB\n')
        (root / 'metadata').mkdir(exist_ok=True)
        (root / 'run').mkdir(exist_ok=True)
        return subprocess.run(['sh', str(SCRIPT), action], env=env, text=True, capture_output=True), calls

    def owned_identity(self, root, phase='ready'):
        identity = root / 'etc/tama-storage'
        identity.mkdir(parents=True)
        (root / 'metadata').mkdir(parents=True, exist_ok=True)
        (root / 'run').mkdir(parents=True, exist_ok=True)
        (identity / 'layout').write_text('zfs-v1\n')
        (identity / 'phase').write_text(phase + '\n')
        (identity / 'pool-guid').write_text('120\n')
        (root / 'metadata' / '.tama-storage-layout').write_text('zfs-v1\n')
        (root / 'run/tama-storage-backend').write_text('zfs\n')

    def test_appliance_does_not_mutate_incus_workloads(self):
        self.assertNotIn('apply_headroom', STORAGE_TEXT)
        self.assertNotIn('workloads/containers', STORAGE_TEXT)
        self.assertNotIn('workloads/virtual-machines', STORAGE_TEXT)

    def test_blank_disk_creates_owned_pool_without_ext4(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            result, calls = self.run_storage(root, disk)
            log = (root / 'storage.log').read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertIn('TAMA_STORAGE_ZFS_CREATED', log)
            recorded = calls.read_text()
            self.assertIn('zpool create', recorded)
            self.assertNotIn('mkfs.ext4', recorded)
            self.assertNotIn('zfs set refreservation=33554432', recorded)
            self.assertEqual((root / 'etc/tama-storage/phase').read_text().strip(), 'preseed-pending')
            self.assertEqual((root / 'etc/tama-storage/layout').read_text().strip(), 'zfs-v1')

    def test_nonzero_tail_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            with disk.open('r+b') as handle:
                handle.seek(4 * 1024 ** 3 - 1)
                handle.write(b'\x01')
            result, calls = self.run_storage(root, disk)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('nonblank', (root / 'storage.log').read_text())
            self.assertNotIn('zpool create', calls.read_text() if calls.exists() else '')

    def test_small_disk_and_low_memory_are_rejected_before_format(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 1024)
            result, _calls = self.run_storage(root, disk)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('at least 4 GiB', (root / 'storage.log').read_text())
            self.assertFalse((root / 'etc/tama-storage/phase').exists())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            result, _calls = self.run_storage(root, disk, memory='2015380')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('below 3670016 KiB', (root / 'storage.log').read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            result, calls = self.run_storage(root, disk, memory='3670016', extra_env={'TAMA_MODPROBE_FAIL': 'zfs'})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertNotIn('below 3670016 KiB', log)
            self.assertIn('module is unavailable', log)
            self.assertNotIn('zpool create', calls.read_text() if calls.exists() else '')

    def test_missing_module_leaves_blank_disk_unformatted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            result, calls = self.run_storage(root, disk, extra_env={'TAMA_MODPROBE_FAIL': 'zfs'})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / 'etc/tama-storage/phase').exists())
            self.assertNotIn('zpool create', calls.read_text() if calls.exists() else '')

    def test_interrupted_intent_on_nonblank_disk_is_not_reformatted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'\0' * 64)
            os.truncate(disk, 4 * 1024 ** 3)
            with disk.open('r+b') as handle:
                handle.seek(10)
                handle.write(b'\x01')
            identity = root / 'etc/tama-storage'
            identity.mkdir(parents=True)
            (identity / 'phase').write_text('intent-blank\n')
            result, calls = self.run_storage(root, disk)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('no recorded pool GUID', (root / 'storage.log').read_text())
            self.assertNotIn('zpool create', calls.read_text() if calls.exists() else '')
            self.assertNotIn('zpool import', calls.read_text() if calls.exists() else '')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'partial-pool')
            identity = root / 'etc/tama-storage'
            identity.mkdir(parents=True)
            (identity / 'phase').write_text('intent-blank\n')
            (root / 'metadata').mkdir()
            (root / 'metadata' / '.tama-storage-layout').write_text('foreign-layout-v2\n')
            result, calls = self.run_storage(root, disk, extra_env={'TAMA_ZPOOL_IMPORT_OK': '1'})
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text() if calls.exists() else ''
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('no recorded pool GUID', log)
            self.assertNotIn('zpool import', recorded)
            self.assertNotIn('zpool create', recorded)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)
            self.assertFalse((identity / 'pool-guid').exists())
            self.assertEqual((root / 'metadata' / '.tama-storage-layout').read_text().strip(), 'foreign-layout-v2')
            self.assertFalse((root / 'metadata/.tama-preseed-pending').exists())
            self.assertEqual((identity / 'phase').read_text().strip(), 'intent-blank')

    def test_recorded_guid_does_not_adopt_foreign_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'partial-pool')
            identity = root / 'etc/tama-storage'
            identity.mkdir(parents=True)
            (identity / 'phase').write_text('intent-blank\n')
            (identity / 'pool-guid').write_text('120\n')
            (root / 'metadata').mkdir()
            (root / 'metadata' / '.tama-storage-layout').write_text('foreign-layout-v2\n')
            result, calls = self.run_storage(root, disk, extra_env={'TAMA_ZPOOL_IMPORT_OK': '1'})
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('foreign metadata layout', log)
            imports = [line for line in recorded.splitlines() if line.startswith('zpool import')]
            self.assertTrue(imports, recorded)
            self.assertTrue(all(line.endswith(' 120') for line in imports), imports)
            self.assertFalse(any(line.endswith(' tama-data') for line in imports), imports)
            self.assertNotIn('zfs set', recorded)
            self.assertEqual((root / 'metadata/.tama-storage-layout').read_text().strip(), 'foreign-layout-v2')
            self.assertFalse((root / 'metadata/.tama-preseed-pending').exists())
            self.assertEqual((identity / 'phase').read_text().strip(), 'intent-blank')

    def test_datasets_ready_resumes_preseed_without_recreate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='datasets-ready')
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            log = (root / 'storage.log').read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertEqual((root / 'etc/tama-storage/phase').read_text().strip(), 'preseed-pending')
            self.assertTrue((root / 'metadata/.tama-preseed-pending').is_file())
            self.assertNotIn('zpool create', calls.read_text())

    def test_pool_created_with_existing_database_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='pool-created')
            metadata = root / 'metadata'
            (metadata / 'database').mkdir()
            (metadata / 'database' / 'db.bin').write_bytes(b'foreign-db')
            (metadata / 'sentinel').write_text('do-not-touch\n')
            before = {
                path.relative_to(metadata).as_posix(): path.read_bytes()
                for path in metadata.rglob('*') if path.is_file()
            }
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            after = {
                path.relative_to(metadata).as_posix(): path.read_bytes()
                for path in metadata.rglob('*') if path.is_file()
            }
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('already has an Incus database', log)
            self.assertNotIn('zpool create', recorded)
            self.assertNotIn('zfs create', recorded)
            self.assertNotIn('zfs set', recorded)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)
            self.assertEqual(before, after)
            self.assertFalse((metadata / '.tama-preseed-pending').exists())
            self.assertEqual((root / 'etc/tama-storage/phase').read_text().strip(), 'pool-created')

    def test_unexpected_mount_is_refused_before_import(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs-pool')
            self.owned_identity(root)
            mounts = root / 'proc-mounts'
            mounts.write_text(f'tmpfs {root / "metadata"} tmpfs rw 0 0\n')
            before = disk.read_bytes()
            result, calls = self.run_storage(
                root, disk, kind='zfs_member',
                extra_env={'TAMA_PROC_MOUNTS': str(mounts), 'TAMA_ZPOOL_IMPORT_OK': '1'})
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text() if calls.exists() else ''
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('unexpected filesystem mounted at metadata target: tmpfs', log)
            self.assertNotIn('zpool import', recorded)
            self.assertNotIn('zpool create', recorded)
            self.assertEqual(disk.read_bytes(), before)

    def test_pool_created_foreign_layout_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='pool-created')
            metadata = root / 'metadata'
            (metadata / '.tama-storage-layout').write_text('foreign-layout-v2\n')
            (metadata / 'sentinel').write_text('keep\n')
            before = {path.relative_to(metadata).as_posix(): path.read_bytes()
                      for path in metadata.rglob('*') if path.is_file()}
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            after = {path.relative_to(metadata).as_posix(): path.read_bytes()
                     for path in metadata.rglob('*') if path.is_file()}
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('foreign metadata layout', log)
            self.assertNotIn('zfs set', recorded)
            self.assertNotIn('zfs create', recorded)
            self.assertEqual(before, after)
            self.assertFalse((metadata / '.tama-preseed-pending').exists())

    def test_unknown_phase_is_not_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='unknown-version-or-interrupted-phase')
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unknown or interrupted phase', (root / 'storage.log').read_text())
            self.assertNotIn('zpool online', calls.read_text() if calls.exists() else '')
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', (root / 'storage.log').read_text())

    def test_label_alone_does_not_authorize_ext4_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'ext4')
            result, calls = self.run_storage(root, disk, kind='ext4', label='tama-incus-data')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('ro,noload', recorded)
            self.assertNotIn('e2fsck', recorded)
            self.assertNotIn('resize2fs', recorded)
            self.assertNotIn('TAMA_STORAGE_EXT4_READY', log)

    def test_wrong_mounted_source_is_not_repaired(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'ext4')
            inspect = root / 'mnt/tama-inspect'
            inspect.mkdir(parents=True)
            (inspect / 'server.crt').write_text('cert')
            (root / 'metadata').mkdir()
            (root / 'metadata' / 'server.crt').write_text('cert')
            mounts = root / 'proc-mounts'
            mounts.write_text(f'/dev/wrong {root / "metadata"} ext4 rw 0 0\n')
            result, calls = self.run_storage(
                root, disk, kind='ext4', label='tama-incus-data',
                extra_env={'TAMA_MOUNTPOINT_PRESENT': '1', 'TAMA_PROC_MOUNTS': str(mounts)})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('/dev/wrong', log)
            self.assertNotIn('e2fsck', calls.read_text())

    def test_recognized_ext4_layout_is_checked_before_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'ext4')
            inspect = root / 'mnt/tama-inspect'
            inspect.mkdir(parents=True)
            (inspect / 'database').mkdir()
            (inspect / 'server.crt').write_text('cert')
            (root / 'metadata' / 'database').mkdir(parents=True)
            (root / 'metadata' / 'server.crt').write_text('cert')
            result, calls = self.run_storage(root, disk, kind='ext4', label='tama-incus-data')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertLess(recorded.index('ro,noload'), recorded.index('e2fsck'))
            self.assertIn('TAMA_STORAGE_EXT4_READY', log)
            self.assertNotIn('zpool create', recorded)

    def test_foreign_zfs_and_wrong_guid_are_not_adopted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('foreign ZFS', (root / 'storage.log').read_text())
            self.assertNotIn('zpool import', calls.read_text() if calls.exists() else '')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            (root / 'etc/tama-storage/pool-guid').write_text('999\n')
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('does not match', (root / 'storage.log').read_text())
            self.assertNotIn('zpool create', calls.read_text())
            self.assertNotIn('zpool import -f', calls.read_text())

    def test_expansion_failure_is_not_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            result, calls = self.run_storage(root, disk, kind='zfs_member',
                                             extra_env={'TAMA_ZPOOL_ONLINE_FAIL': '1'})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('vdev expansion failed', log)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)
            self.assertIn('zpool online', calls.read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            result, _calls = self.run_storage(
                root, disk, kind='zfs_member', extra_env={'TAMA_ZPOOL_EXPANDSIZE': '33554432'})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('still pending', log)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)

    def test_proc_mounts_source_is_used_when_findmnt_is_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            mounts = root / 'proc-mounts'
            mounts.write_text(f'other-dataset {root / "metadata"} zfs rw 0 0\n')
            result, _calls = self.run_storage(
                root, disk, kind='zfs_member',
                extra_env={'TAMA_MOUNTPOINT_PRESENT': '1', 'TAMA_PROC_MOUNTS': str(mounts)})
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('other-dataset', log)
            self.assertNotIn('TAMA_STORAGE_ZFS_READY', log)

    def test_owned_pool_imports_without_workload_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            result, calls = self.run_storage(root, disk, kind='zfs_member')
            log = (root / 'storage.log').read_text()
            recorded = calls.read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertIn('zpool online', recorded)
            self.assertNotIn('zpool create', recorded)
            self.assertNotIn('refreservation=268435456', recorded)
            self.assertIn('TAMA_STORAGE_ZFS_READY', log)

    def test_ready_requires_backend_profile_and_live_headroom(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            result, _calls = self.run_storage(root, disk, action='ready')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('missing or unknown', (root / 'storage.log').read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root, phase='preseed-pending')
            result, calls = self.run_storage(root, disk, action='ready')
            log = (root / 'storage.log').read_text()
            self.assertNotEqual(result.returncode, 0, log)
            self.assertIn('phase is not ready', log)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disk = root / 'disk'
            disk.write_bytes(b'zfs')
            self.owned_identity(root)
            result, calls = self.run_storage(root, disk, action='ready')
            log = (root / 'storage.log').read_text()
            self.assertEqual(result.returncode, 0, log)
            self.assertIn('TAMA_STORAGE_DRIVER_OK', log)
            self.assertIn('incus query /1.0/profiles/default', calls.read_text())
