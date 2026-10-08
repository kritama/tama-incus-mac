#!/usr/bin/env python3
"""Explicit installed-bottle hardware phases; failures retain the isolated appliance."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

MODULE = Path(__file__).resolve().parents[2] / "Packaging/homebrew/candidate.py"
SPEC = importlib.util.spec_from_file_location("homebrew_candidate", MODULE)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


def fixture_paths(root, first=False):
    if not Path(root).is_absolute():
        raise ValueError("Use an absolute short isolated test root")
    root = candidate.safe_path(root)
    state, client = candidate.safe_path(root / "state"), candidate.safe_path(root / "client")
    candidate.safe_path(root / "hardware.json")
    if len(str(state)) > 80:
        raise ValueError("Use an absolute short isolated test root")
    if root == Path.home() or root == Path("/"):
        raise ValueError("Refusing an ordinary test root")
    if first and root.exists() and any(root.iterdir()):
        raise ValueError("First acceptance requires a fresh empty test root")
    return root, state, client


def service_label(state):
    # Foundation standardizes Darwin's /private/tmp and /private/var aliases.
    path = str(state)
    for alias in ("/private/tmp/", "/private/var/"):
        if path.startswith(alias):
            path = path.removeprefix("/private")
            break
    return "com.upmaru.macus." + hashlib.sha256(path.encode()).hexdigest()[:12]


def require_upgrade(report, manifest):
    stopped = report.get("stopped_version")
    if not report.get("checks", {}).get("stopped_and_unloaded") or not stopped:
        raise ValueError("Resume requires a recorded successful stop and unload")
    if stopped == manifest["version"]:
        raise ValueError("Resume requires a different installed package candidate")


def execute(arguments, env, report, timeout=1800):
    result = subprocess.run(arguments, env=env, text=True, capture_output=True, timeout=timeout)
    report.setdefault("commands", []).append({"tool": Path(arguments[0]).name,
        "arguments": arguments[1:], "exit_code": result.returncode,
        "stdout": result.stdout[-4000:], "stderr": result.stderr[-4000:]})
    if result.returncode:
        raise ValueError(f"{Path(arguments[0]).name} failed; inspect retained hardware report")
    return result.stdout.strip()


def ensure_marker(incus, instance, env, report, state):
    token = hashlib.sha256(str(state).encode()).hexdigest()
    key = "user.macus.homebrew-acceptance"
    instances = json.loads(execute([incus, "list", instance, "--format=json"], env, report))
    matches = [value for value in instances if value.get("name") == "macus-brew-marker"]
    if matches:
        if len(matches) != 1 or matches[0].get("config", {}).get(key) != token:
            raise ValueError("Refusing an unrelated existing marker instance")
        if matches[0].get("status") == "Stopped":
            execute([incus, "start", instance], env, report)
    else:
        execute([incus, "launch", "images:alpine/3.24", instance, "-c", "boot.autostart=true",
                 "-c", key + "=" + token], env, report)
    execute([incus, "exec", instance, "--", "sh", "-c",
             "printf macus-brew-persistence > /root/macus-marker"], env, report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--phase", choices=["start", "retry-start", "stop", "resume", "removed"], required=True)
    parser.add_argument("--opt-in", action="store_true")
    parser.add_argument("--hardware", action="store_true")
    args = parser.parse_args()
    if not args.opt_in or not args.hardware:
        raise ValueError("Requires explicit --opt-in --hardware before any mutation")
    root, state, client = fixture_paths(args.root, first=args.phase == "start")
    _, manifest = candidate.load(args.candidate)
    label = service_label(state)
    if args.phase == "start":
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        client.mkdir(mode=0o700)
        report = {"schema_version": 1, "hardware_ran": True, "state": str(state),
                  "incus_conf": str(client), "service_label": label, "checks": {}}
    else:
        report = json.loads((root / "hardware.json").read_text())
        if (report.get("state"), report.get("incus_conf"), report.get("service_label")) != (str(state), str(client), label):
            raise ValueError("Hardware report does not match isolated fixture identity")
    if args.phase == "resume":
        require_upgrade(report, manifest)
    env = dict(os.environ, INCUS_CONF=str(client), MACUS_STATE_DIR=str(state), HOMEBREW_NO_AUTO_UPDATE="1")
    remote = "macus-brew"
    instance = remote + ":macus-brew-marker"
    incus = shutil.which("incus")
    if not incus:
        raise ValueError("Install the standard Incus client before hardware acceptance")
    report.setdefault("candidate_history", []).append({"phase": args.phase, "version": manifest["version"],
                                                       "source_commit": manifest["source_commit"]})
    try:
        if args.phase == "removed":
            installed = subprocess.run(["brew", "list", "--versions", "macus"], capture_output=True, text=True)
            if installed.returncode == 0 and installed.stdout.strip():
                raise ValueError("Macus is still installed")
            job = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"], capture_output=True)
            if job.returncode == 0 or not (state / "runtime/data.raw").is_file() or not any(client.iterdir()):
                raise ValueError("Removal did not preserve isolated data or unload its service")
            report["checks"]["uninstall_preserves_data"] = True
        else:
            candidate.verify(args.candidate)
            prefix = Path(candidate.run(["brew", "--prefix", candidate.FORMULA])).resolve(strict=True)
            binary = str(prefix / "bin/macus")
            report["installed_binary"] = binary
            if args.phase in ("start", "retry-start", "resume"):
                command = [binary, "--state-dir", str(state), "--json", "--progress", "none",
                           "--incus", incus, "start", "--remote", remote]
                for attempt in range(2 if args.phase in ("start", "retry-start") else 1):
                    result = json.loads(execute(command, env, report))
                    if result.get("ready") is not True or result.get("connected") is not True or result.get("service_label") != label:
                        raise ValueError("Installed startup did not reach isolated live readiness")
                execute([incus, "list", remote + ":", "--format=json"], env, report)
                if args.phase in ("start", "retry-start") and not report["checks"].get("first_and_repeated_start"):
                    ensure_marker(incus, instance, env, report, state)
                    report["checks"]["first_and_repeated_start"] = True
                marker = execute([incus, "exec", instance, "--", "cat", "/root/macus-marker"], env, report)
                if marker != "macus-brew-persistence":
                    raise ValueError("Workload marker did not survive package transition")
                report["checks"]["marker_" + args.phase] = True
            else:
                execute([binary, "--state-dir", str(state), "--json", "runtime", "stop"], env, report)
                status = json.loads(execute([binary, "--state-dir", str(state), "--json", "runtime", "status"], env, report))
                if status.get("state") != "stopped":
                    raise ValueError("Runtime did not stop before package change")
                execute(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label}"], env, report)
                report["checks"]["stopped_and_unloaded"] = True
                report["stopped_version"] = manifest["version"]
        report["last_phase_success"] = True
    except Exception as error:
        report["last_phase_success"] = False
        report["failure"] = str(error)
        raise
    finally:
        candidate.write_text(root / "hardware.json", json.dumps(report, indent=2) + "\n")
    print(root / "hardware.json")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        raise SystemExit(str(error))
