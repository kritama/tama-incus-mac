"""Kernel reboot must leave a durable bootstrap continuation, not a one-shot runcmd."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

BOOTSTRAP = Path(__file__).resolve().parents[1] / 'guest/bootstrap.sh'


def write_stub(directory, name, body):
    path = directory / name
    path.write_text('#!/bin/sh\n' + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


class BootstrapContinuationTests(unittest.TestCase):
    def run_boot(self, root, kernel):
        bin_dir = root / 'bin'
        bin_dir.mkdir(exist_ok=True)
        calls = root / 'calls'
        for name in ('rc-service', 'dhcpcd', 'update-ca-certificates', 'sysctl',
                     'modprobe', 'incus', 'incusd', 'poweroff'):
            write_stub(bin_dir, name, f'printf "%s %s\\n" "{name}" "$*" >> "{calls}"\n')
        write_stub(bin_dir, 'ip', f'printf "ip %s\\n" "$*" >> "{calls}"\nprintf "%s\\n" "default via 192.168.64.1"\n')
        write_stub(bin_dir, 'uname', f'if [ "$1" = -r ]; then printf "%s\\n" "{kernel}"; fi\n')
        write_stub(bin_dir, 'rc-update', f'printf "rc-update %s\\n" "$*" >> "{calls}"\n')
        write_stub(bin_dir, 'apk', f'''
printf "apk %s\\n" "$*" >> "{calls}"
if [ "$1" = info ]; then printf '%s\\n' 'linux-lts-6.18.55-r0'; fi
''')
        write_stub(bin_dir, 'seq', 'printf "1\\n"\n')
        write_stub(root / 'bin', 'storage', f'printf "storage %s\\n" "$*" >> "{calls}"\n')
        env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', TAMA_BOOT_ROOT=str(root),
                   TAMA_STORAGE_SCRIPT=str(root / 'bin/storage'))
        return subprocess.run(['sh', str(BOOTSTRAP)], env=env, text=True, capture_output=True), calls

    def prepare(self, root):
        for path in ('etc', 'etc/init.d', 'etc/apk', 'etc/network', 'var/log', 'var/lib/incus', 'run', 'sys/fs/cgroup'):
            (root / path).mkdir(parents=True, exist_ok=True)
        (root / 'etc/init.d/tama-bootstrap').write_text('#!/sbin/openrc-run\n')
        (root / 'etc/init.d/tama-bootstrap').chmod(0o755)
        (root / 'etc/resolv.conf').write_text('nameserver 1.1.1.1\n')
        (root / 'etc/network/interfaces').write_text('auto eth0\n')
        (root / 'etc/dhcpcd.conf').write_text('# tama-incus IPv4 DHCP\n')
        (root / 'etc/os-release').write_text('ID=alpine\nVERSION_ID=3.24.2\n')
        (root / 'etc/rc.conf').write_text('rc_cgroup_mode="hybrid"\n')
        (root / 'etc/subuid').write_text('root:1:1\n')
        (root / 'etc/subgid').write_text('root:1:1\n')
        (root / 'sys/fs/cgroup/cgroup.controllers').write_text('cpu\n')
        (root / 'run/tama-storage-backend').write_text('zfs\n')
        (root / 'var/lib/incus/.tama-preseed-pending').write_text('pending\n')

    def test_kernel_mismatch_enables_continuation_before_poweroff(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.prepare(root)
            result, calls = self.run_boot(root, '6.18.52-0-lts')
            output = result.stdout + result.stderr
            recorded = calls.read_text()
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('MACUS_OBSERVATION v1 stage=kernel_transition state=expected_reboot', output)
            self.assertLess(
                output.index('MACUS_OBSERVATION v1 stage=kernel_transition state=expected_reboot'),
                output.index('TAMA_ZFS_KERNEL_REBOOT_REQUIRED'))
            self.assertIn('TAMA_ZFS_KERNEL_REBOOT_REQUIRED', output)
            self.assertLess(recorded.index('rc-update add tama-bootstrap'), recorded.index('poweroff'))
            self.assertNotIn('rc-update add incusd', recorded)
            self.assertFalse((root / 'var/lib/tama-bootstrap-complete').exists())

    def test_repeated_boot_continues_after_kernel_matches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.prepare(root)
            (root / 'etc/tama-zfs-qualified-kernel').write_text('6.18.55-0-lts\n')
            result, calls = self.run_boot(root, '6.18.55-0-lts')
            output = result.stdout + result.stderr
            recorded = calls.read_text()
            self.assertEqual(result.returncode, 0, output + recorded)
            self.assertIn('MACUS_OBSERVATION v1 stage=packages', output)
            self.assertIn('MACUS_OBSERVATION v1 stage=storage', output)
            self.assertIn('MACUS_OBSERVATION v1 stage=incus', output)
            self.assertIn('MACUS_OBSERVATION v1 stage=ready', output)
            self.assertLess(output.index('MACUS_OBSERVATION v1 stage=ready'), output.index('TAMA_BOOTSTRAP_READY'))
            self.assertIn('TAMA_BOOTSTRAP_READY', output)
            self.assertNotIn('poweroff', recorded)
            self.assertIn('rc-update add incusd', recorded)
            self.assertIn('rc-update del tama-bootstrap', recorded)
            self.assertTrue((root / 'var/lib/tama-bootstrap-complete').is_file())
            second, second_calls = self.run_boot(root, '6.18.55-0-lts')
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertIn('TAMA_BOOTSTRAP_ALREADY_COMPLETE', second.stdout)
            self.assertNotIn('poweroff', second_calls.read_text() if second_calls.exists() else '')

    def test_completed_marker_without_kernel_record_does_not_reprovision(self):
        for record in (None, ''):
            with self.subTest(record=record), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.prepare(root)
                (root / 'var/lib/tama-bootstrap-complete').write_text('complete\n')
                if record is not None:
                    (root / 'etc/tama-zfs-qualified-kernel').write_text(record)
                result, calls = self.run_boot(root, '6.18.55-0-lts')
                recorded = calls.read_text() if calls.exists() else ''
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('MACUS_OBSERVATION v1 stage=failed code=kernel_record_missing', result.stderr)
                self.assertIn('TAMA_BOOTSTRAP_KERNEL_RECORD_MISSING', result.stderr)
                self.assertNotIn('apk ', recorded)
                self.assertNotIn('poweroff', recorded)
                self.assertNotIn('storage ', recorded)
                self.assertNotIn('incus ', recorded)

    def test_completed_marker_with_different_kernel_record_still_continues(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.prepare(root)
            (root / 'var/lib/tama-bootstrap-complete').write_text('complete\n')
            (root / 'etc/tama-zfs-qualified-kernel').write_text('6.18.55-0-lts\n')
            result, calls = self.run_boot(root, '6.18.52-0-lts')
            recorded = calls.read_text()
            output = result.stdout + result.stderr
            self.assertNotIn('TAMA_BOOTSTRAP_KERNEL_RECORD_MISSING', output)
            self.assertIn('apk ', recorded)
            self.assertIn('poweroff', recorded)
