#!/bin/sh
set -eu
swift build -Xswiftc -warnings-as-errors
# Keep unrelated fixture startup out of deadline measurements; tests exercise concurrency internally.
swift test --no-parallel -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift format lint --strict --recursive Package.swift Sources Tests
sh -n Integration/guest/bootstrap.sh
sh -n Integration/guest/storage.sh
sh -n Integration/guest/tama-storage.initd
sh -n Integration/guest/tama-bridge.initd
sh -n Integration/guest/tama-bootstrap.initd
sh -n Integration/qualification/zfs-storage.sh
sh -n Packaging/install-local.sh
sh -n Integration/scripts/test-install.sh
python3 -m py_compile Integration/guest/bridge.py Integration/scripts/prepare-appliance.py Integration/scripts/verify-appliance.py Integration/scripts/acceptance.py Integration/scripts/storage_contract.py Integration/scripts/relay-stress.py Integration/scripts/macus-acceptance.py Integration/scripts/start-acceptance.py Integration/scripts/sync-guest-payload.py Integration/scripts/check-catalog.py
python3 Integration/scripts/sync-guest-payload.py --check
python3 Integration/scripts/check-catalog.py
python3 -m py_compile Integration/qualification/prepare-zfs.py Integration/qualification/run-zfs.py
python3 -m unittest discover -s Integration/tests -v
sh Integration/scripts/test-install.sh
