# Per-user packaging

Build and ad-hoc sign a development binary using docs/development.md. For a persistent local installation, copy it to a user-owned absolute path, replace `@BINARY_PATH@` and `@STATE_PATH@` in the LaunchAgent template with absolute paths (XML-escape values), and save the completed plist under `~/Library/LaunchAgents/com.kritama.tama-incus-mac.plist`. Validate with `plutil -lint`, then bootstrap using `launchctl bootstrap gui/$(id -u) <absolute-plist-path>`. Unload using `launchctl bootout gui/$(id -u)/com.kritama.tama-incus-mac`. This is opt-in; project checks do not install an agent or modify launchd.

The service starts its API on login and boots Linux only when requested through the control API. Unloading preserves disk state. `ExitTimeOut` exceeds the default graceful shutdown timeout; explicit callers can choose longer deadlines. Development binaries are not signed/notarized distribution artifacts.
