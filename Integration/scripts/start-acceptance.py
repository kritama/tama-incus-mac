#!/usr/bin/env python3
"""Opt-in macus start acceptance.

Refuses ordinary user state and client configuration. Does not boot hardware
unless --hardware is explicit. Failure artifacts are retained.
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
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--macus", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--incus", type=Path)
    parser.add_argument("--remote", default="macus")
    parser.add_argument("--hardware", action="store_true")
    parser.add_argument("--opt-in", action="store_true")
    return parser.parse_args()


def lexical(path):
    return Path(os.path.abspath(path))


def is_within(child, parent):
    try:
        lexical(child).relative_to(lexical(parent))
        return True
    except ValueError:
        return False


def is_platform_alias(path):
    if path not in (Path("/tmp"), Path("/var")):
        return False
    try:
        return os.readlink(path) in ("private" + str(path), "/private" + str(path))
    except OSError:
        return False


def reject_report_ancestry(report):
    node = lexical(report)
    seen = []
    while True:
        seen.append(node)
        if node.parent == node:
            break
        node = node.parent
    for candidate in reversed(seen):
        if candidate == lexical(report) and not os.path.lexists(candidate):
            continue
        if not os.path.lexists(candidate):
            continue
        if os.path.islink(candidate):
            if is_platform_alias(candidate):
                continue
            raise SystemExit(f"Refusing symlink report ancestry: {candidate}")
        if candidate != lexical(report) and not os.path.isdir(candidate):
            raise SystemExit(f"Report ancestry is not a directory: {candidate}")


def validate_report(report, state, prefix, macus):
    """Reject destinations that could replace runtime, install, or client data.

    This runs before any directory creation, report write, or executable invocation.
    """
    if not Path(report).is_absolute():
        raise SystemExit("Report path must be absolute")
    reject_report_ancestry(report)
    if os.path.islink(report):
        raise SystemExit("Refusing a symlink report destination")
    if os.path.lexists(report) and not os.path.isfile(report):
        raise SystemExit("Report destination must be a regular file")
    protected = [
        lexical(state),
        lexical(prefix),
        lexical(Path.home() / ".tama" / "incus-mac"),
        lexical(Path.home() / ".config" / "incus"),
    ]
    if macus:
        protected.append(lexical(macus))
    destination = lexical(report)
    for root in protected:
        if destination == root or is_within(destination, root):
            raise SystemExit(
                "Refusing a report destination inside runtime, installation, or client data")
    resolved_state = Path(state).resolve()
    resolved_prefix = Path(prefix).resolve()
    try:
        resolved_report = Path(report).resolve()
    except OSError as error:
        raise SystemExit(f"Cannot resolve report destination: {error}") from error
    for root in (resolved_state, resolved_prefix):
        try:
            resolved_report.relative_to(root)
        except ValueError:
            continue
        raise SystemExit(
            "Refusing a report destination that resolves inside runtime or installation data")


def refuse_user_paths(state, prefix, client):
    home_state = (Path.home() / ".tama" / "incus-mac").resolve()
    user_incus = (Path.home() / ".config" / "incus").resolve()
    resolved = state.resolve()
    if resolved == home_state or ".tama/incus-mac" in str(resolved):
        raise SystemExit("Refusing the normal ~/.tama/incus-mac state directory")
    if len(str(resolved)) > 80:
        raise SystemExit("Refusing a state path that is not short enough for Unix sockets")
    if prefix.resolve() == home_state or prefix.resolve() == Path.home():
        raise SystemExit("Refusing an ordinary installation prefix")
    if client.resolve() == user_incus:
        raise SystemExit("Refusing the normal Incus client configuration")


def main():
    args = parse_args()
    if not args.opt_in:
        raise SystemExit("Refusing to run without --opt-in")
    # Validate the report before creating client directories, state, or running macus.
    validate_report(args.report, args.state_dir, args.prefix, args.macus)
    state = args.state_dir
    prefix = args.prefix
    client = Path(tempfile.mkdtemp(prefix="macus-start-incus-conf-"))
    refuse_user_paths(state, prefix, client)
    state.mkdir(parents=True, exist_ok=True)
    os.chmod(state, 0o700)
    report = {
        "schema_version": 1,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "scope": "Opt-in macus start with isolated state, INCUS_CONF and a session-only agent",
        "hardware_ran": False,
        "guest_verified": False,
        "brew_install_ran": False,
        "state_dir": str(state.resolve()),
        "prefix": str(prefix.resolve()),
        "incus_conf": str(client.resolve()),
        "checks": {},
    }
    report_path = args.report

    def save():
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n")

    save()
    if not args.hardware:
        report["checks"]["refused_without_hardware_opt_in"] = True
        report["note"] = "Hardware acceptance was not run. Fixture or unit success is not physical first-use evidence."
        save()
        raise SystemExit("Hardware acceptance was not run; pass --hardware to execute macus start")
    macus = args.macus.resolve(strict=True)
    env = dict(os.environ, INCUS_CONF=str(client), MACUS_BREW_FALLBACK="0")
    command = [
        str(macus), "--state-dir", str(state.resolve()), "--json", "--progress", "plain",
        "--timeout", "1800", "start", "--remote", args.remote,
    ]
    if args.incus:
        command[1:1] = ["--incus", str(args.incus.resolve(strict=True))]
    # Nondefault state keeps the agent session-only and out of the default LaunchAgents plist.
    try:
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=1800)
        report.setdefault("commands", []).append({
            "tool": "macus", "arguments": command[1:], "exit_code": result.returncode,
            "stdout": result.stdout[-4000:], "stderr": result.stderr[-4000:],
        })
        report["hardware_ran"] = True
        if result.returncode == 0:
            body = json.loads(result.stdout)
            report["checks"]["ready"] = body.get("ready") is True
            report["checks"]["connected"] = body.get("connected") is True
            report["guest_verified"] = body.get("ready") is True and body.get("connected") is True
            report["success"] = report["guest_verified"]
        else:
            report["success"] = False
            report["note"] = "Start failed. State, logs and this report were preserved."
    except Exception as error:
        report["success"] = False
        report["note"] = f"Acceptance failed and artifacts were preserved: {error}"
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        save()
    if not report.get("success"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
