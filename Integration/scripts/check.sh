#!/bin/sh
set -eu
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift format lint --strict --recursive Package.swift Sources Tests
sh -n Integration/guest/bootstrap.sh
sh -n Integration/guest/storage.sh
sh -n Integration/guest/tama-storage.initd
sh -n Integration/guest/tama-bridge.initd
python3 -m py_compile Integration/guest/bridge.py Integration/scripts/prepare-appliance.py Integration/scripts/verify-appliance.py Integration/scripts/acceptance.py
