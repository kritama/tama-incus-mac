# Design

## Context

See proposal.md for motivation. Package.swift currently exports TamaIncusMac plus tama-incus-mac and tim executable products. Daemon.run and TimCLI already isolate serving and client requests in the library. Both discover the same default state directory. The installer signs two binaries differently; a unified binary must carry the virtualization entitlement.

## Goals / Non-Goals

**Goals:** One CLI identity with the existing commands and safety boundaries; consistent module, logging, packaging and documentation names; deterministic state compatibility.

**Non-Goals:** Changing Incus API transport, guest images, persistent formats, runtime routes or hosting/release state.

## Decisions

1. Export `Macus` and `macus` from a package named `macus`, with source folders `Sources/Macus`, `Sources/MacusCommand` (explicit executable target path avoids case-insensitive collision with Macus) and `Tests/MacusTests`. Keep VZ implementation inside `Sources/Macus/Virtualization`; the executable delegates to a library dispatcher.
2. Route leading `serve` to the daemon; route exact `capabilities` to the existing host detector; route other commands to the renamed client grammar. One help lists all modes. Serve validates its own flags before creating state; JSON usage errors remain client-compatible. Serving accepts `--state-dir` after `serve`, matching launchd.
3. Share state resolution: explicit flag, `MACUS_STATE_DIR`, legacy `TIM_STATE_DIR`, then `~/.tama/incus-mac`. Retaining the default avoids implicit appliance migration, ambiguous double-state selection or copying large disks. Retain the persisted reset intent string and guest bootstrap/service/storage identifiers; these are compatibility data. Rename the new client remote default to `macus`; existing `tama-mac` registrations stay untouched and can be reused with `--remote tama-mac`.
4. Install only `macus`, signed with VZ entitlement. Reject symlink/non-file destinations before building and copying; leave existing legacy binaries alone. Rename the launchd template to `com.kritama.macus` without activating it. Document unloading an old agent before opting into the new one to avoid competing state ownership.
5. Update current code, scripts, docs and project instructions. Keep archived/completed change artifacts, historical reports and past acceptance narratives unmodified; explicitly identify the rename as superseding dual-executable instructions. Keep verified GitHub links pointing at their actual repository URLs.

## Risks / Trade-offs

- Existing scripts naming old binaries need updating: document the command mapping rather than installing aliases that perpetuate two names.
- One executable carries a VZ entitlement even for client commands: client paths still never create a VM or start the daemon implicitly.
- Old state/guest identifiers remain visible internally: document their compatibility role rather than risking data-loss through cosmetic replacement.

## Migration Plan

Validate planning, rename and combine entrypoints, update installer/tooling and docs, then run canonical checks and strict OpenSpec validation. Use only temporary state/prefixes for tests; do not boot hardware or activate services. Rollback is rebuilding the preceding source; persisted appliance state remains readable. Hardware acceptance reports retain their original binary names and do not qualify the renamed binary.
