#!/bin/sh
set -eu
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift format lint --strict --recursive Package.swift Sources Tests
bash -n Integration/guest/bootstrap.sh
sh -n Integration/guest/storage.sh
python3 -m py_compile Integration/guest/bridge.py Integration/scripts/prepare-appliance.py Integration/scripts/acceptance.py
