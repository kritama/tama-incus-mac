import Foundation

struct IncusExecutableResolution: Sendable, Equatable {
  var executable: String
  var installed: Bool
}

struct IncusSetupResult: Sendable, Equatable {
  var address: String
  var connected: Bool
  var isDefault: Bool
  var executable: String
  var installed: Bool
  var remote: String
  var onPath: Bool
}

enum IncusAvailability: Sendable, Equatable {
  case executable(String)
  case homebrew(String)
  case missing
}

/// Discovery, official Homebrew installation and remote registration for the standard Incus CLI.
///
/// `client setup` and `start` share this service. It does not boot a runtime or install Homebrew.
struct IncusClientService: Sendable {
  var runner: any LocalCommandRunner
  var streams: MacusStreams
  var environment: [String: String]

  func availability(override: String?) throws -> IncusAvailability {
    if let override {
      guard isAbsoluteExecutablePath(override),
        FileManager.default.isExecutableFile(atPath: override)
      else {
        throw RuntimeError(.invalidConfiguration, "--incus must be an executable file")
      }
      return .executable(override)
    }
    if let found = executable(named: "incus", path: environment["PATH"] ?? "") {
      return .executable(found)
    }
    if let brew = brewExecutable(environment: environment) { return .homebrew(brew) }
    return .missing
  }

  func resolve(
    override: String?, timeout: Int, deadline: ContinuousClock.Instant? = nil
  ) async throws -> IncusExecutableResolution {
    switch try availability(override: override) {
    case .executable(let path):
      return IncusExecutableResolution(executable: path, installed: false)
    case .missing:
      throw RuntimeError(
        .unavailable,
        "Incus CLI was not found on PATH and Homebrew is not installed. Install Homebrew from https://brew.sh, then rerun macus client setup. macus does not install Homebrew."
      )
    case .homebrew(let brew):
      if let existing = try await installedIncus(brew: brew, timeout: timeout, deadline: deadline) {
        try finishWithin(deadline)
        return IncusExecutableResolution(executable: existing, installed: false)
      }
      streams.writeError(
        "macus: Incus CLI not found; installing official Homebrew formula incus\n")
      var brewEnvironment = environment
      if brewEnvironment["HOMEBREW_NO_AUTO_UPDATE"] == nil {
        brewEnvironment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
      }
      let install = try await run(
        executable: brew, arguments: ["install", "incus"], environment: brewEnvironment,
        timeout: timeout, deadline: deadline)
      if !install.stderr.isEmpty {
        let progress = String(decoding: install.stderr, as: UTF8.self)
        streams.writeError(terminalSafe(String(progress.prefix(4_000))))
        if !progress.hasSuffix("\n") { streams.writeError("\n") }
      }
      guard install.status == 0 else {
        throw RuntimeError(.io, "Homebrew install of incus failed")
      }
      guard
        let installed = try await installedIncus(brew: brew, timeout: timeout, deadline: deadline)
      else {
        throw RuntimeError(
          .unavailable, "Homebrew installed incus but the executable was not found under its prefix"
        )
      }
      try finishWithin(deadline)
      return IncusExecutableResolution(executable: installed, installed: true)
    }
  }

  func setup(
    remote: String, setDefault: Bool, incusOverride: String?, directory: URL, timeout: Int,
    transport: any LocalHTTPTransport
  ) async throws -> IncusSetupResult {
    if let incusOverride {
      guard isAbsoluteExecutablePath(incusOverride),
        FileManager.default.isExecutableFile(atPath: incusOverride)
      else {
        throw RuntimeError(.invalidConfiguration, "--incus must be an executable file")
      }
    }
    let status = try await readyRuntimeStatus(
      directory: directory, timeout: timeout, transport: transport, command: "client setup")
    let socket = URL(fileURLWithPath: status.incusSocket)
    try validatePrivateUnixSocket(socket)
    return try await register(
      remote: remote, setDefault: setDefault, incusOverride: incusOverride,
      socketPath: socket.path, timeout: timeout, deadline: nil)
  }

  /// Registers a remote against an already validated private socket. Does not boot the runtime.
  ///
  /// A nil deadline preserves client setup's per-command timeout. Start passes one shared deadline.
  func register(
    remote: String, setDefault: Bool, incusOverride: String?, socketPath: String, timeout: Int,
    deadline: ContinuousClock.Instant? = nil
  ) async throws -> IncusSetupResult {
    let resolved = try await resolve(override: incusOverride, timeout: timeout, deadline: deadline)
    let address = "unix:\(socketPath)"
    let previousDefault = try await incusDefault(
      resolved.executable, timeout: timeout, deadline: deadline)
    let remotes = try await incusRemotes(resolved.executable, timeout: timeout, deadline: deadline)
    if let existing = remotes[remote] {
      guard addressesMatch(existing, socketPath) else {
        throw RuntimeError(
          .conflict,
          "Remote \(remote) already points at a different address. macus client setup does not overwrite it."
        )
      }
    } else {
      try await requireSuccess(
        executable: resolved.executable, arguments: ["remote", "add", remote, address],
        timeout: timeout, deadline: deadline, failure: "incus remote add failed")
    }
    var selectedDefault = previousDefault
    if setDefault {
      try await requireSuccess(
        executable: resolved.executable, arguments: ["remote", "switch", remote],
        timeout: timeout, deadline: deadline, failure: "incus remote switch failed")
      selectedDefault = remote
    } else if let previousDefault {
      let current = try await incusDefault(
        resolved.executable, timeout: timeout, deadline: deadline)
      if current != previousDefault {
        try await requireSuccess(
          executable: resolved.executable, arguments: ["remote", "switch", previousDefault],
          timeout: timeout, deadline: deadline,
          failure: "Cannot restore the previous default remote")
      }
      selectedDefault = previousDefault
    }
    try await requireSuccess(
      executable: resolved.executable, arguments: ["list", "\(remote):"], timeout: timeout,
      deadline: deadline, failure: "incus list could not use the registered remote")
    try finishWithin(deadline)
    return IncusSetupResult(
      address: address, connected: true, isDefault: selectedDefault == remote,
      executable: resolved.executable, installed: resolved.installed, remote: remote,
      onPath: pathContains(URL(fileURLWithPath: resolved.executable).deletingLastPathComponent())
    )
  }

  func conflictingRemote(
    executable: String, remote: String, socketPath: String, timeout: Int,
    deadline: ContinuousClock.Instant? = nil
  ) async throws -> Bool {
    let remotes = try await incusRemotes(executable, timeout: timeout, deadline: deadline)
    guard let existing = remotes[remote] else { return false }
    return !addressesMatch(existing, socketPath)
  }

  private func installedIncus(
    brew: String, timeout: Int, deadline: ContinuousClock.Instant?
  ) async throws -> String? {
    for arguments in [["--prefix"], ["--prefix", "incus"]] {
      let result = try await run(
        executable: brew, arguments: arguments, environment: environment, timeout: timeout,
        deadline: deadline)
      guard result.status == 0,
        let prefix = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines), isAbsoluteExecutablePath(prefix)
      else { continue }
      let candidate = URL(fileURLWithPath: prefix).appendingPathComponent("bin/incus").path
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  private func incusRemotes(
    _ executable: String, timeout: Int, deadline: ContinuousClock.Instant?
  ) async throws -> [String: [String]] {
    let result = try await requireSuccess(
      executable: executable, arguments: ["remote", "list", "--format", "json"], timeout: timeout,
      deadline: deadline, failure: "incus remote list failed")
    guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
    else {
      throw RuntimeError(.io, "incus remote list returned malformed JSON")
    }
    var remotes: [String: [String]] = [:]
    for (name, value) in object {
      let info = value as? [String: Any]
      remotes[name] = info?["Addrs"] as? [String] ?? []
    }
    return remotes
  }

  private func incusDefault(
    _ executable: String, timeout: Int, deadline: ContinuousClock.Instant?
  ) async throws -> String? {
    let result = try await run(
      executable: executable, arguments: ["remote", "get-default"], environment: environment,
      timeout: timeout, deadline: deadline)
    guard result.status == 0,
      let text = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines), !text.isEmpty
    else {
      throw RuntimeError(
        .io, "Cannot read the existing Incus default remote; configuration was not changed")
    }
    return text
  }

  @discardableResult
  private func requireSuccess(
    executable: String, arguments: [String], timeout: Int, deadline: ContinuousClock.Instant?,
    failure: String
  ) async throws -> LocalCommandResult {
    let result = try await run(
      executable: executable, arguments: arguments, environment: environment, timeout: timeout,
      deadline: deadline)
    guard result.status == 0 else {
      let detail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      let suffix = detail.isEmpty ? "" : ": \(detail.prefix(500))"
      throw RuntimeError(.io, "\(failure)\(suffix)")
    }
    return result
  }

  private func run(
    executable: String, arguments: [String], environment: [String: String], timeout: Int,
    deadline: ContinuousClock.Instant?
  ) async throws -> LocalCommandResult {
    let limit = try childTimeout(timeout, deadline: deadline)
    return try await runner.run(
      executable: executable, arguments: arguments, environment: environment, timeout: limit)
  }

  /// Whole seconds still inside the original deadline. Nil keeps each client-setup command on its
  /// own timeout. A partial second is not rounded up into a new second.
  private func childTimeout(_ fallback: Int, deadline: ContinuousClock.Instant?) throws -> Int {
    guard let deadline else { return fallback }
    try Task.checkCancellation()
    let now = ContinuousClock.now
    guard now < deadline else { throw RuntimeError(.timeout, "Startup deadline exceeded") }
    let whole = now.duration(to: deadline).components.seconds
    guard whole >= 1 else { throw RuntimeError(.timeout, "Startup deadline exceeded") }
    return min(fallback, Int(whole))
  }

  private func finishWithin(_ deadline: ContinuousClock.Instant?) throws {
    if let deadline, ContinuousClock.now >= deadline {
      throw RuntimeError(.timeout, "Startup deadline exceeded")
    }
  }

  private func pathContains(_ directory: URL) -> Bool {
    let path = environment["PATH"] ?? ""
    return path.split(separator: ":").contains { candidate in
      URL(fileURLWithPath: String(candidate)).standardizedFileURL.path
        == directory.standardizedFileURL.path
    }
  }
}

func brewExecutable(environment: [String: String]) -> String? {
  if let found = executable(named: "brew", path: environment["PATH"] ?? "") { return found }
  guard environment["MACUS_BREW_FALLBACK"] != "0" else { return nil }
  for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}

func executable(named name: String, path: String) -> String? {
  for directory in path.split(separator: ":") where !directory.isEmpty {
    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}

func addressesMatch(_ stored: [String], _ socketPath: String) -> Bool {
  stored.contains { unixSocketPath($0) == socketPath }
}

func unixSocketPath(_ address: String) -> String? {
  if address.hasPrefix("unix://") {
    let rest = String(address.dropFirst("unix://".count))
    return rest.hasPrefix("/") ? rest : nil
  }
  if address.hasPrefix("unix:") {
    let rest = String(address.dropFirst("unix:".count))
    return rest.hasPrefix("/") ? rest : nil
  }
  return nil
}

func isAbsoluteExecutablePath(_ path: String) -> Bool {
  path.hasPrefix("/") && !path.utf8.contains(0) && !path.contains("\n") && !path.contains("\r")
}

struct ReadyRuntimeStatus {
  let apiVersion: Int
  let state: String
  let incusSocket: String
}

func readyRuntimeStatus(
  directory: URL, timeout: Int, transport: any LocalHTTPTransport, command: String
) async throws -> ReadyRuntimeStatus {
  let socket = try controlSocketURL(directory.appendingPathComponent("runtime.sock"))
  let response = try await transport.request(
    socket: socket, method: "GET", path: "/v1/runtime/status", body: Data(), timeout: timeout)
  guard (200...299).contains(response.status) else {
    throw responseFailure(status: response.status, body: response.body)
  }
  let object = try jsonObject(response.body)
  guard let api = jsonInt(object["api_version"]), let state = jsonString(object["state"]),
    let incus = jsonString(object["incus_socket"]), incus.hasPrefix("/")
  else { throw RuntimeError(.io, "Malformed runtime status") }
  guard api == 1 else {
    throw RuntimeError(
      .invalidConfiguration,
      "Incompatible runtime API version \(api); this macus client supports version 1")
  }
  guard state == "ready" else {
    throw RuntimeError(
      .unavailable,
      "Runtime is \(state), not ready. macus \(command) does not start the appliance; run macus runtime start"
    )
  }
  return ReadyRuntimeStatus(apiVersion: api, state: state, incusSocket: incus)
}

func controlSocketURL(_ url: URL) throws -> URL {
  guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count < 104 else {
    throw RuntimeError(
      .invalidConfiguration, "Unix socket path exceeds 103 bytes; choose a shorter state directory")
  }
  return url
}
