#!/usr/bin/env python3
"""Check the shipped catalog against reviewable provenance. Does not boot a VM."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Integration" / "catalog" / "alpine-3.24.2.json"
SWIFT = ROOT / "Sources" / "Macus" / "Bootstrap" / "ApplianceCatalog.swift"
PAYLOAD = ROOT / "Sources" / "Macus" / "Bootstrap" / "EmbeddedGuestPayload.swift"


def main():
    catalog = json.loads(CATALOG.read_text())
    required = [
        "archive_sha512", "raw_sha256", "archive_bytes", "raw_bytes", "archive_url",
        "archive_name", "member_name", "signer_fingerprint", "id",
    ]
    missing = [key for key in required if key not in catalog]
    if missing:
        raise SystemExit(f"Catalog is missing {missing}")
    if not re.fullmatch(r"[0-9a-f]{128}", catalog["archive_sha512"]):
        raise SystemExit("Archive SHA-512 is not a real 128-digit digest")
    if not re.fullmatch(r"[0-9a-f]{64}", catalog["raw_sha256"]):
        raise SystemExit("Raw SHA-256 is not a real 64-digit digest")
    if catalog["archive_bytes"] <= 0 or catalog["raw_bytes"] <= 0:
        raise SystemExit("Catalog sizes must be positive measured values")
    if catalog["signer_fingerprint"] != "F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22":
        raise SystemExit("Catalog signer does not match the pinned Alpine cloud key")
    swift = SWIFT.read_text().replace("_", "")
    payload = PAYLOAD.read_text()
    for key in ("archive_sha512", "raw_sha256", "archive_url", "archive_name", "signer_fingerprint"):
        if catalog[key] not in swift:
            raise SystemExit(f"ApplianceCatalog.swift does not contain catalog {key}")
    for key in ("archive_bytes", "raw_bytes"):
        if str(catalog[key]) not in swift:
            raise SystemExit(f"ApplianceCatalog.swift does not contain catalog {key}")
    match = re.search(r'static let revision = "([0-9a-f]{64})"', payload)
    if not match:
        raise SystemExit("Embedded guest payload has no revision")
    if catalog.get("guest_payload_revision") != match.group(1):
        raise SystemExit("Catalog guest_payload_revision does not match embedded payload")
    if "verify-appliance.py" not in catalog.get("verified_with", ""):
        raise SystemExit("Catalog does not record signature-verification tooling")
    print("catalog provenance matches embedded payload")


if __name__ == "__main__":
    main()
