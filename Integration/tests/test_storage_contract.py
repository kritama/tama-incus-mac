"""Production acceptance rejects the wrong ZFS contract before workloads."""
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from storage_contract import assert_production_zfs, snapshot_restore_markers


def pool(**config):
    base = {
        'source': 'tama-data/workloads',
        'volume.zfs.reserve_space': 'true',
        'volume.zfs.use_refquota': 'true',
    }
    base.update(config)
    return {'driver': 'zfs', 'config': base}


def profile(pool_name='default', size='2GiB'):
    return {'devices': {'root': {'pool': pool_name, 'size': size}}}


class StorageContractTests(unittest.TestCase):
    def test_valid_contract(self):
        self.assertTrue(assert_production_zfs(pool(), profile()))

    def test_wrong_driver(self):
        value = pool()
        value['driver'] = 'dir'
        with self.assertRaises(AssertionError) as caught:
            assert_production_zfs(value, profile())
        self.assertIn('dir', str(caught.exception))

    def test_wrong_source(self):
        with self.assertRaises(AssertionError) as caught:
            assert_production_zfs(pool(source='tama-data'), profile())
        self.assertIn('tama-data', str(caught.exception))

    def test_wrong_profile_pool(self):
        with self.assertRaises(AssertionError) as caught:
            assert_production_zfs(pool(), profile(pool_name='other'))
        self.assertIn('other', str(caught.exception))

    def test_refused_older_restore_keeps_newer_original_marker(self):
        markers = snapshot_restore_markers('abc123')
        self.assertEqual(markers['snapshot_s1'], 'abc123')
        self.assertEqual(markers['copied_s1'], 'abc123')
        self.assertEqual(markers['original_after_refused_restore'], 'abc123-2')
        self.assertNotEqual(markers['original_after_refused_restore'], markers['copied_s1'])
        acceptance = Path(__file__).resolve().parents[1].joinpath('scripts/acceptance.py').read_text()
        self.assertIn('markers = snapshot_restore_markers(marker)', acceptance)
        after = acceptance.split('older_snapshot_restore_refused_and_copy_preserved', 1)[1]
        self.assertIn("marker = markers['original_after_refused_restore']", after)
        self.assertLess(after.index("marker = markers['original_after_refused_restore']"),
                        after.index('persistent_marker(marker)'))

    def test_missing_creation_time_reservation(self):
        with self.assertRaises(AssertionError):
            assert_production_zfs(pool(**{'volume.zfs.reserve_space': 'false'}), profile())
