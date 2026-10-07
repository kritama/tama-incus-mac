# Per-user packaging

One Macus installation supplies the `macus` executable. From a checkout with Swift installed:

```sh
Packaging/install-local.sh --prefix /absolute/path
```

The default prefix is `~/.local`. Use an absolute isolated prefix for tests and acceptance; do not point it at a runtime state directory. The installer builds, stages, ad-hoc signs and verifies one `macus` binary, then installs it into `prefix/bin`. The executable carries `com.apple.security.virtualization` for its `serve` mode. Client commands still require explicit runtime operations and never start the daemon implicitly. Existing runtime data is not created or modified.

This source install requires Swift and produces development ad-hoc signatures. It does not install Homebrew, the Incus CLI or a launch agent. `macus client setup` is the explicit later step for the standard Incus CLI. No formula or checksum is published until real release artifacts exist.

Build and ad-hoc sign a development binary using docs/development.md. For a persistent local installation, copy it to a user-owned absolute path, replace `@BINARY_PATH@` and `@STATE_PATH@` in `Packaging/launchd/com.upmaru.macus.plist.in` with absolute paths (XML-escape values), and save the completed plist under `~/Library/LaunchAgents/com.upmaru.macus.plist`. Validate with `plutil -lint`, then bootstrap using `launchctl bootstrap gui/$(id -u) <absolute-plist-path>`. Unload using `launchctl bootout gui/$(id -u)/com.upmaru.macus`. This template starts the control API at login and does not boot Linux until a runtime command asks for it. Project checks do not install an agent or modify launchd. `macus start` can register this default agent, or a session-only `com.upmaru.macus.<state-hash>` agent under an explicit nondefault state. Isolated start does not replace `~/Library/LaunchAgents/com.upmaru.macus.plist`.

The service starts its API on login and boots Linux only when requested through the control API. Unloading preserves disk state. `ExitTimeOut` exceeds the default graceful shutdown timeout; explicit callers can choose longer deadlines. Development binaries are not signed/notarized distribution artifacts.

When replacing an existing launch agent, explicitly unload `com.kritama.tama-incus-mac` and `com.kritama.macus`, and remove those plists from LaunchAgents, before installing `com.upmaru.macus`. Set its binary path to the installed `macus` and keep its existing state path. Do not activate both a legacy agent and `com.upmaru.macus` against one directory. `macus start` detects those legacy registrations and stops rather than unloading them or starting a second daemon. The installer leaves legacy executables in place and does not perform this service transition. Service logs use the `com.upmaru.macus` subsystem.
