"""Production ZFS acceptance checks that do not require a live VM."""


def snapshot_restore_markers(initial):
    """After a refused older restore, the original keeps its newer data."""
    if not initial or initial.endswith('-2'):
        raise ValueError('initial marker must be distinct from the newer write')
    updated = initial + '-2'
    return {
        'snapshot_s1': initial,
        'original_after_refused_restore': updated,
        'copied_s1': initial,
    }


def assert_production_zfs(pool, profile):
    """Reject a fresh ZFS appliance whose Incus default is not the owned layout."""
    driver = pool.get('driver')
    config = pool.get('config') or {}
    if driver != 'zfs':
        raise AssertionError(f'unexpected driver: {driver}')
    if config.get('source') != 'tama-data/workloads':
        raise AssertionError(f'unexpected source: {config.get("source")}')
    if config.get('volume.zfs.reserve_space') != 'true' or config.get('volume.zfs.use_refquota') != 'true':
        raise AssertionError('Incus creation-time reservation policy is missing')
    root = (profile.get('devices') or {}).get('root') or {}
    if root.get('pool') != 'default':
        raise AssertionError(f'unexpected profile root pool: {root.get("pool")}')
    if not root.get('size'):
        raise AssertionError('default profile root has no size for creation-time reservation')
    return True
