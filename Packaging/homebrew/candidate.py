#!/usr/bin/env python3
"""Generate traceable Homebrew candidates; package mutations always require opt-in."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
from urllib.parse import urlparse
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "Packaging/homebrew/Formula/macus.rb.in"
TAP = "upmaru/macus-local"
FORMULA = TAP + "/macus"


def run(arguments, cwd=None, log=None, timeout=1800):
    environment = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1")
    if log:
        log = safe_path(log)
        with log.open("ab") as output:
            process = subprocess.Popen(arguments, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True, env=environment)
            try:
                status = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise ValueError(f"Command timed out; retained log: {log}")
        if status:
            raise ValueError(f"Command failed ({status}); retained log: {log}")
        return ""
    return subprocess.run(arguments, cwd=cwd, check=True, capture_output=True,
                          text=True, timeout=timeout, env=environment).stdout.strip()


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def ruby_string(value):
    return json.dumps(value).replace("#{", "\\#{")


def safe_path(path):
    path = Path(os.path.abspath(path))
    for node in (path, *path.parents):
        if node.is_symlink() and node not in (Path("/tmp"), Path("/var")):
            raise ValueError(f"Refusing symlink path: {node}")
    return path


def write_text(path, text):
    path = safe_path(path)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(text)


def checked_sha(value):
    if not re.fullmatch(r"[0-9a-f]{64}", value) or len(set(value)) == 1:
        raise ValueError("Missing, invalid or placeholder SHA-256")
    return value


def render(manifest, bottle_root=None, source_url=None, template=None):
    bottle = ""
    if manifest.get("bottles"):
        lines = ["  bottle do", f"    root_url {ruby_string(bottle_root or manifest['bottle_root'])}"]
        rebuild = manifest.get("bottle_rebuild", 0)
        if type(rebuild) is not int or rebuild < 0:
            raise ValueError("Invalid Homebrew bottle rebuild")
        if rebuild:
            lines.append(f"    rebuild {rebuild}")
        for tag, info in sorted(manifest["bottles"].items()):
            if not re.fullmatch(r"arm64_[a-z0-9_]+", tag):
                raise ValueError("Bottles must use an ARM64 macOS tag")
            cellar = info["cellar"]
            cellar = ":" + cellar if cellar in ("any", "any_skip_relocation") else ruby_string(cellar)
            lines.append(f"    sha256 cellar: {cellar}, {tag}: {ruby_string(checked_sha(info['sha256']))}")
        lines.extend(["  end", ""])
        bottle = "\n".join(lines)
    text = (template or TEMPLATE).read_text()
    for key, value in {"SOURCE_URL": ruby_string(source_url or manifest["source_url"]),
                       "VERSION": ruby_string(manifest["version"]),
                       "SOURCE_SHA256": ruby_string(checked_sha(manifest["source_sha256"])),
                       "BOTTLE": bottle}.items():
        text = text.replace("@" + key + "@", value)
    return text


def save(root, manifest):
    write_text(root / "candidate.json", json.dumps(manifest, indent=2) + "\n")
    write_text(root / "tap/Formula/macus.rb", render(manifest, template=root / "formula.rb.in"))


def load(root):
    root = safe_path(root)
    data = json.loads((root / "candidate.json").read_text())
    if data.get("schema_version") != 1 or not re.fullmatch(r"[0-9a-f]{40}", data["source_commit"]):
        raise ValueError("Invalid candidate provenance")
    if not re.fullmatch(r"0\.0\.0-dev\.[0-9]{14}\.[0-9a-f]{12}", data["version"]):
        raise ValueError("Invalid development version")
    if not data["version"].endswith(data["source_commit"][:12]):
        raise ValueError("Candidate version does not identify its source commit")
    template = safe_path(root / "formula.rb.in")
    if digest(template) != checked_sha(data["formula_template_sha256"]):
        raise ValueError("Candidate formula template integrity failed")
    source = root / data["source_file"]
    if source.parent != root or source.is_symlink() or digest(source) != checked_sha(data["source_sha256"]):
        raise ValueError("Candidate source integrity failed")
    for info in data.get("bottles", {}).values():
        path = root / info["local_filename"]
        if path.parent != root or path.is_symlink() or digest(path) != checked_sha(info["sha256"]):
            raise ValueError("Candidate bottle integrity failed")
    return root, data


def prepare(output, repo=ROOT, stamp=None):
    if run(["git", "status", "--porcelain"], cwd=repo):
        raise ValueError("Candidate generation requires a clean committed checkout")
    commit = run(["git", "rev-parse", "HEAD"], cwd=repo)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Candidate generation requires an immutable commit")
    root = safe_path(output)
    if root.exists():
        raise ValueError("Refusing to reuse an existing candidate directory")
    root.mkdir(parents=True, mode=0o700)
    stamp = stamp or datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    version = f"0.0.0-dev.{stamp}.{commit[:12]}"
    source = root / f"macus-{version}.tar.gz"
    run(["git", "archive", "--format=tar.gz", f"--prefix=macus-{version}/", "-o", str(source), commit], cwd=repo)
    template_text = run(["git", "show", f"{commit}:Packaging/homebrew/Formula/macus.rb.in"], cwd=repo) + "\n"
    write_text(root / "formula.rb.in", template_text)
    (root / "tap/Formula").mkdir(parents=True)
    manifest = {"schema_version": 1, "source_commit": commit, "version": version,
                "source_file": source.name, "source_url": source.as_uri(),
                "source_sha256": digest(source), "bottle_root": root.as_uri(),
                "formula_template_sha256": digest(root / "formula.rb.in"),
                "signing_mode": "ad-hoc-development", "architecture": platform.machine(),
                "host_macos": platform.mac_ver()[0], "deployment_target": "15.0",
                "swift_version": run(["swift", "--version"]), "bottles": {}}
    save(root, manifest)
    run(["git", "init", "-b", "main"], cwd=root / "tap")
    run(["git", "add", "Formula/macus.rb"], cwd=root / "tap")
    run(["git", "-c", "user.name=Macus packaging", "-c", "user.email=packaging@localhost",
         "commit", "--no-gpg-sign", "-m", "Prepare local Macus candidate"], cwd=root / "tap")
    return root, manifest


def require_opt_in(args):
    if not args.opt_in:
        raise ValueError("Homebrew mutations require --opt-in")


def refuse_package_conflict():
    result = subprocess.run(["brew", "list", "--versions", "macus"], capture_output=True, text=True)
    if result.returncode == 0 and result.stdout.strip():
        raise ValueError("Refusing an existing Macus package; use a dedicated package environment")
    executable = shutil.which("macus")
    if executable:
        raise ValueError(f"Refusing an existing macus executable on PATH: {executable}")


def attach_local(root):
    taps = run(["brew", "tap"]).splitlines()
    if TAP in taps:
        location = Path(run(["brew", "--repository", TAP]))
        if run(["git", "remote", "get-url", "origin"], cwd=location) != str(root / "tap"):
            raise ValueError("Refusing an unrelated existing local tap")
    else:
        run(["brew", "tap", TAP, str(root / "tap")], log=root / "build.log")
    run(["brew", "trust", "--formula", FORMULA], log=root / "build.log")
    return Path(run(["brew", "--repository", TAP]))


def verify_binary(binary):
    run(["/usr/bin/codesign", "--verify", "--strict", str(binary)])
    result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(binary)],
                            check=True, capture_output=True, text=True)
    if "com.apple.security.virtualization" not in result.stdout + result.stderr:
        raise ValueError("Installed binary is missing its virtualization entitlement")
    if "serve" not in run([str(binary), "--help"], cwd=binary.parent) or "apple-vz" not in run([str(binary), "capabilities"], cwd=binary.parent):
        raise ValueError("Installed executable smoke checks failed")


def passive_snapshot():
    snapshot = []
    for path in (Path.home() / ".tama/incus-mac", Path.home() / ".config/incus",
                 Path.home() / "Library/LaunchAgents/com.upmaru.macus.plist"):
        info = path.lstat() if os.path.lexists(path) else None
        snapshot.append((info.st_mode, info.st_size, info.st_mtime_ns) if info else None)
    job = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/com.upmaru.macus"],
                         capture_output=True, timeout=10)
    snapshot.append(job.returncode == 0)
    return snapshot


def build(args):
    require_opt_in(args)
    root, manifest = load(args.candidate)
    refuse_package_conflict()
    tap = attach_local(root)
    run(["brew", "install", "--build-bottle", FORMULA], log=root / "build.log")
    binary = Path(run(["brew", "--prefix", FORMULA])) / "bin/macus"
    verify_binary(binary)
    run(["brew", "test", FORMULA], log=root / "build.log")
    run(["brew", "bottle", "--json", "--root-url=" + root.as_uri(), FORMULA], cwd=root, log=root / "build.log")
    records = list(root.glob("*.bottle.json"))
    if len(records) != 1:
        raise ValueError("Expected exactly one Homebrew bottle JSON record")
    record = json.loads(records[0].read_text())[FORMULA]
    if record["formula"]["pkg_version"] != manifest["version"]:
        raise ValueError("Bottle version does not match candidate")
    manifest["bottle_rebuild"] = record["bottle"]["rebuild"]
    manifest["bottles"] = {tag: {"filename": info["filename"], "local_filename": info["local_filename"],
                               "sha256": info["sha256"], "cellar": record["bottle"]["cellar"]}
                            for tag, info in record["bottle"]["tags"].items()}
    save(root, manifest)
    load(root)
    for info in manifest["bottles"].values():
        # Homebrew emits a double-hyphen local filename and a single-hyphen URL filename.
        destination = safe_path(root / info["filename"])
        if destination.parent != root:
            raise ValueError("Unsafe bottle URL filename")
        if not destination.exists():
            with destination.open("xb") as output, (root / info["local_filename"]).open("rb") as source:
                shutil.copyfileobj(source, output)
        if digest(destination) != info["sha256"]:
            raise ValueError("Conflicting bottle URL filename")
    write_text(tap / "Formula/macus.rb", render(manifest, template=root / "formula.rb.in"))
    run(["brew", "style", FORMULA], log=root / "style.log")
    run(["brew", "audit", "--strict", FORMULA], log=root / "audit.log")
    print(root / "candidate.json")


def install(args):
    require_opt_in(args)
    root, manifest = load(args.candidate)
    if not manifest["bottles"]:
        raise ValueError("Build a verified bottle before installation acceptance")
    refuse_package_conflict()
    before = passive_snapshot()
    tap = attach_local(root)
    write_text(tap / "Formula/macus.rb", render(manifest, template=root / "formula.rb.in"))
    run(["brew", "install", "--force-bottle", FORMULA], log=root / "install.log")
    if passive_snapshot() != before:
        raise ValueError("Package installation changed ordinary runtime/client/service state")
    verify(root)


def verify(root):
    root, manifest = load(root)
    prefix = Path(run(["brew", "--prefix", FORMULA])).resolve(strict=True)
    receipt = json.loads((prefix / "INSTALL_RECEIPT.json").read_text())
    if not receipt.get("poured_from_bottle") or receipt.get("source", {}).get("tap") != TAP:
        raise ValueError("Installed receipt is not a poured candidate from the expected tap")
    if prefix.name != manifest["version"]:
        raise ValueError("Installed package version does not match candidate")
    verify_binary(prefix / "bin/macus")
    report = {"schema_version": 1, "source_commit": manifest["source_commit"],
              "version": manifest["version"], "formula": FORMULA, "installed_keg": str(prefix),
              "bottles": manifest["bottles"], "poured_from_bottle": True,
              "signature_verified": True, "virtualization_entitlement": True,
              "hardware_ran": False, "host_macos": platform.mac_ver()[0], "success": True}
    write_text(root / "package-acceptance.json", json.dumps(report, indent=2) + "\n")
    print(root / "package-acceptance.json")


def export(args):
    root, manifest = load(args.candidate)
    if not manifest["bottles"]:
        raise ValueError("Cannot export an unbottled candidate")
    urls = [(args.source_url, manifest["source_sha256"])]
    for info in manifest["bottles"].values():
        urls.append((args.bottle_root.rstrip("/") + "/" + info["filename"], info["sha256"]))
    for url, expected in urls:
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.username or parsed.password or manifest["version"] not in parsed.path:
            raise ValueError("Shared formula requires version-specific immutable HTTPS asset URLs")
        with urlopen(url, timeout=60) as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != checked_sha(expected):
            raise ValueError(f"Remote artifact checksum mismatch: {url}")
    destination = safe_path(args.destination)
    if destination.exists():
        raise ValueError("Refusing to replace an existing exported formula")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("x") as output:
        output.write(render(manifest, args.bottle_root, args.source_url, root / "formula.rb.in"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare").add_argument("--output", type=Path, required=True)
    for name in ("build", "install", "verify", "export"):
        sub = commands.add_parser(name)
        sub.add_argument("--candidate", type=Path, required=True)
        if name in ("build", "install"):
            sub.add_argument("--opt-in", action="store_true")
        if name == "export":
            sub.add_argument("--source-url", required=True)
            sub.add_argument("--bottle-root", required=True)
            sub.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        root, _ = prepare(args.output)
        print(root / "candidate.json")
    elif args.command == "verify":
        verify(args.candidate)
    else:
        globals()[args.command](args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        raise SystemExit(str(error))
