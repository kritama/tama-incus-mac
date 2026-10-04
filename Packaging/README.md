# Per-user packaging

One tama-incus-mac installation supplies both executables. From a checkout with Swift installed:

```sh
Packaging/install-local.sh --prefix /absolute/path
```

The default prefix is `~/.local`. Use an absolute isolated prefix for tests and acceptance; do not point it at a runtime state directory. The command builds the release daemon and `tim`, stages them, ad-hoc signs and verifies both, and installs them into `prefix/bin`. Only the daemon receives `com.apple.security.virtualization`. tim is a client and is signed without that entitlement. Existing runtime data is not created or modified. Launchd is not installed or started; the template below remains an explicit, separate step for the daemon only.

This is a local source install. It requires Swift and produces development ad-hoc signatures, not a notarized production artifact. It does not install Homebrew or the Incus CLI. `tim client setup` is the explicit later step for the official Homebrew `incus` formula when that CLI is missing. A future release package must contain both tama-incus-mac tools. No formula or checksum is published until real release artifacts exist.

Build and ad-hoc sign a development binary using docs/development.md. For a persistent local installation, copy it to a user-owned absolute path, replace `@BINARY_PATH@` and `@STATE_PATH@` in the LaunchAgent template with absolute paths (XML-escape values), and save the completed plist under `~/Library/LaunchAgents/com.kritama.tama-incus-mac.plist`. Validate with `plutil -lint`, then bootstrap using `launchctl bootstrap gui/$(id -u) <absolute-plist-path>`. Unload using `launchctl bootout gui/$(id -u)/com.kritama.tama-incus-mac`. This is opt-in; project checks do not install an agent or modify launchd.

The service starts its API on login and boots Linux only when requested through the control API. Unloading preserves disk state. `ExitTimeOut` exceeds the default graceful shutdown timeout; explicit callers can choose longer deadlines. Development binaries are not signed/notarized distribution artifacts.
