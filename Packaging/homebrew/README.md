# Homebrew release boundary

No formula is published yet: there is no release URL, immutable source checksum, signed/notarized binary or production appliance catalog. Do not ship a formula with placeholder checksums. A future formula should require macOS 15+ and Apple Silicon, install an entitled release binary, provide a per-user service, and preserve state on uninstall. Build/test commands are in docs/development.md. The Incus CLI is optional for users and required only by the interoperability acceptance script.
