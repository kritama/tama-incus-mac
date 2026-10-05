#!/usr/bin/env python3
"""Opt-in tim client-setup acceptance.

Uses the standard Incus CLI only to prove a registered remote. Does not start,
stop, reconfigure or reprovision a runtime, and refuses the normal Incus client
configuration. Historical lifecycle evidence is a different gate.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import tempfile


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--tim", type=Path, required=True)
    parser.add_argument("--incus", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--remote", default="tama-mac")
    return parser.parse_args()


args = parse_args()
state = args.state_dir.resolve(strict=True)
home_state = Path.home() / ".tama" / "incus-mac"
if state == home_state.resolve() or ".tama/incus-mac" in str(state):
    raise SystemExit("Refusing the normal ~/.tama/incus-mac state directory")
user_incus = Path.home() / ".config" / "incus"
tim = args.tim.resolve(strict=True)
incus = args.incus.resolve(strict=True)
report = {
    "schema_version": 1,
    "recorded_at": datetime.now(timezone.utc).isoformat(),
    "scope": "Installed tim client setup with the standard Incus CLI and an isolated INCUS_CONF",
    "brew_install_ran": False,
    "lifecycle_gate": False,
    "checks": {},
}
client = Path(tempfile.mkdtemp(prefix="tim-incus-conf-"))
if client.resolve() == user_incus.resolve():
    raise SystemExit("Refusing the normal Incus client configuration")
env = dict(os.environ, INCUS_CONF=str(client), TIM_BREW_FALLBACK="0")


def save():
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")


def run(tool, args_list, timeout=60):
    result = subprocess.run(
        [str(tool), *args_list], env=env, text=True, capture_output=True, timeout=timeout)
    report.setdefault("commands", []).append({
        "tool": tool.name, "arguments": args_list, "exit_code": result.returncode,
        "stdout": result.stdout[-4000:], "stderr": result.stderr[-4000:],
    })
    save()
    return result


try:
    before = run(incus, ["remote", "get-default"])
    if before.returncode or not before.stdout.strip():
        raise RuntimeError(before.stderr or "Cannot read the default remote before setup")
    original_default = before.stdout.strip()
    report["default_before"] = original_default
    setup = run(tim, [
        "--state-dir", str(state), "--incus", str(incus), "--json", "--timeout", "30",
        "client", "setup", "--remote", args.remote,
    ])
    if setup.returncode:
        raise RuntimeError(setup.stderr)
    body = json.loads(setup.stdout)
    assert body["remote"] == args.remote, body
    assert body["connected"] is True, body
    assert body["installed"] is False, body
    report["checks"]["registered"] = True
    listed = run(incus, ["list", args.remote + ":"])
    if listed.returncode:
        raise RuntimeError(listed.stderr)
    report["checks"]["incus_list"] = True
    default = run(incus, ["remote", "get-default"])
    if default.returncode:
        raise RuntimeError(default.stderr or "incus remote get-default failed")
    report["default_after"] = default.stdout.strip()
    unchanged = default.stdout.strip() == original_default
    report["checks"]["default_unchanged"] = unchanged
    if not unchanged:
        raise RuntimeError("setup changed the default remote without --set-default")
    again = run(tim, [
        "--state-dir", str(state), "--incus", str(incus), "--json", "--timeout", "30",
        "client", "setup", "--remote", args.remote,
    ])
    if again.returncode:
        raise RuntimeError(again.stderr)
    report["checks"]["idempotent"] = True
    report["success"] = True
finally:
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    save()
if not report.get("success"):
    raise SystemExit(1)
