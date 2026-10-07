# Per-user packaging

One Macus installation supplies the `macus` executable. From a checkout with Swift installed:

```sh
Packaging/install-local.sh --prefix /absolute/path
```

The default prefix is `~/.local`. Use an absolute isolated prefix for tests and acceptance; do not point it at a runtime state directory. The installer builds, stages, ad-hoc signs and verifies one `macus` binary, then installs it into `prefix/bin`. The executable carries `com.apple.security.virtualization` for its `serve` mode. Client commands still require explicit runtime operations and never start the daemon implicitly. Existing runtime data is not created or modified.

This source install requires Swift and produces development ad-hoc signatures. It does not install Homebrew, the Incus CLI or a launch agent. `macus client setup` is the explicit later step for the standard Incus CLI. No formula or checksum is published until real release artifacts exist.

Build and ad-hoc sign a development binary using docs/development.md. For a persistent local installation, copy it to a user-owned absolute path, replace `@BINARY_PATH@` and `@STATE_PATH@` in the LaunchAgent template with absolute paths (XML-escape values), and save the completed plist under `~/Library/LaunchAgents/com.kritama.macus.plist`. Validate with `plutil -lint`, then bootstrap using `launchctl bootstrap gui/$(id -u) <absolute-plist-path>`. Unload using `launchctl bootout gui/$(id -u)/com.kritama.macus`. This is opt-in; project checks do not install an agent or modify launchd.

The service starts its API on login and boots Linux only when requested through the control API. Unloading preserves disk state. `ExitTimeOut` exceeds the default graceful shutdown timeout; explicit callers can choose longer deadlines. Development binaries are not signed/notarized distribution artifacts.

When replacing an existing launch agent, explicitly unload `com.kritama.tama-incus-mac` and remove its old plist from LaunchAgents before installing the new `com.kritama.macus` template. Set its binary path to the installed `macus` and keep its existing state path. Do not activate both agents against one directory. The installer leaves legacy executables in place and does not perform this service transition.
