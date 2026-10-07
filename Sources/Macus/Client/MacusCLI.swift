import Foundation

public struct MacusStreams: Sendable {
  public var writeOutput: @Sendable (String) -> Void
  public var writeError: @Sendable (String) -> Void

  public static let standard = MacusStreams(
    writeOutput: { text in
      try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    },
    writeError: { text in
      try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }
  )
}

/// Thin local grammar and request orchestration for the `macus` executable.
///
/// Read-only commands never create state, boot the appliance, install software, or mutate Incus.
/// Workload operations belong to the standard incus client.
public enum MacusCLI {
  public static let defaultRemoteName = "macus"
  public static let readOnlyTimeout = 10
  public static let lifecycleTimeout = 650

  public static func run(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    transport: any LocalHTTPTransport = UnixHTTPClient(),
    streams: MacusStreams = .standard
  ) async -> Int32 {
    let json = requestsJSON(arguments)
    do {
      if arguments.isEmpty || arguments == ["--help"] {
        streams.writeOutput(helpText)
        return 0
      }
      if arguments.first == "serve" || arguments == ["capabilities"] {
        try await Daemon.run(arguments: arguments, environment: environment)
        return 0
      }
      let invocation = try parse(arguments)
      let directory = try stateDirectory(flag: invocation.stateDirectory, environment: environment)
      let timeout = invocation.timeout ?? defaultTimeout(invocation.command)
      try await execute(
        invocation.command, directory: directory, timeout: timeout, json: invocation.json,
        environment: environment, transport: transport, runner: ProcessCommandRunner(),
        streams: streams)
      return 0
    } catch let error as UsageError {
      emit(RuntimeError(.invalidRequest, error.message), json: json, streams: streams)
      return 2
    } catch let error as RuntimeError {
      emit(error, json: json, streams: streams)
      return arguments.first == "serve" && error.code == .invalidRequest ? 2 : 1
    } catch {
      emit(RuntimeError(.io, error.localizedDescription), json: json, streams: streams)
      return 1
    }
  }

  /// Resolves the flag, Macus environment, legacy environment, then the existing default.
  /// This does not create, chmod or stat the directory.
  public static func stateDirectory(flag: String?, environment: [String: String]) throws -> URL {
    if let flag {
      guard isAbsolute(flag) else {
        throw RuntimeError(.invalidRequest, "--state-dir requires an absolute path")
      }
      return URL(fileURLWithPath: flag, isDirectory: true)
    }
    let key = environment["MACUS_STATE_DIR"] != nil ? "MACUS_STATE_DIR" : "TIM_STATE_DIR"
    if let env = environment[key] {
      guard isAbsolute(env) else {
        throw RuntimeError(.invalidConfiguration, "\(key) must be an absolute path")
      }
      return URL(fileURLWithPath: env, isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(
      ".tama/incus-mac", isDirectory: true)
  }

  public static var helpText: String {
    """
    macus — native macOS Incus host

    Usage: macus [--state-dir ABSOLUTE_PATH] [--json] [--timeout SECONDS] <command>

    Commands:
      serve [--state-dir ABSOLUTE_PATH]
      capabilities
      runtime status
      runtime start
      runtime stop [--force]
      runtime restart
      doctor
      client setup [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH]

    The outer runtime is the Apple VZ appliance. runtime commands and doctor use
    the existing control API and never install software or boot implicitly.
    Workload operations belong to the standard incus client. client setup registers
    that client against the ready runtime socket. The default remote name is
    \(defaultRemoteName). --set-default is required to change the selected default.
    If incus is not on PATH, setup installs the official Homebrew formula incus
    when Homebrew is already installed. It does not install Homebrew.

    serve runs the foreground daemon; capabilities reports host support without booting.
    Serve flags follow serve. Other commands accept global flags around the command.
    State directory: --state-dir, then MACUS_STATE_DIR, then legacy TIM_STATE_DIR,
    then ~/.tama/incus-mac. The existing default preserves appliance data.
    Selecting a state directory does not create it. Invalid flags fail before
    networking or installation. Timeout is \(readOnlyTimeout) seconds for read-only
    requests and \(lifecycleTimeout) seconds for runtime start, stop, restart and
    client setup (1...3600). A restart or Homebrew install may need a larger value.
    Exit status is 0 on success, 1 on operational failure and 2 on invalid arguments.

    """
  }
}

private struct UsageError: Error {
  let message: String
}

private enum Command {
  case runtimeStatus
  case runtimeStart
  case runtimeStop(force: Bool)
  case runtimeRestart
  case doctor
  case clientSetup(remote: String, setDefault: Bool, incus: String?)
}

private struct Invocation {
  var stateDirectory: String?
  var json: Bool
  var timeout: Int?
  var command: Command
}

private func requestsJSON(_ arguments: [String]) -> Bool {
  var index = 0
  while index < arguments.count {
    let token = arguments[index]
    if token == "--json" { return true }
    if token == "--timeout" || token == "--state-dir" || token == "--remote"
      || token == "--incus"
    {
      index += 2
      continue
    }
    index += 1
  }
  return false
}

private func isAbsolute(_ path: String) -> Bool {
  path.hasPrefix("/") && !path.utf8.contains(0) && !path.contains("\n") && !path.contains("\r")
}

private func defaultTimeout(_ command: Command) -> Int {
  switch command {
  case .runtimeStart, .runtimeStop, .runtimeRestart, .clientSetup: MacusCLI.lifecycleTimeout
  case .runtimeStatus, .doctor: MacusCLI.readOnlyTimeout
  }
}

private func parse(_ arguments: [String]) throws -> Invocation {
  var index = 0
  var json = false
  var timeout: Int?
  var stateDirectory: String?
  var force = false
  var setDefault = false
  var remote: String?
  var incusOverride: String?
  var positionals: [String] = []
  func value(for flag: String) throws -> String {
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
      throw UsageError(message: "\(flag) requires a value")
    }
    index += 1
    return arguments[index]
  }
  while index < arguments.count {
    let token = arguments[index]
    switch token {
    case "--json":
      guard !json else { throw UsageError(message: "Duplicate --json") }
      json = true
    case "--timeout":
      guard timeout == nil else { throw UsageError(message: "Duplicate --timeout") }
      let raw = try value(for: "--timeout")
      guard raw.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(raw),
        (1...3600).contains(parsed)
      else { throw UsageError(message: "--timeout must be an integer from 1 to 3600") }
      timeout = parsed
    case "--state-dir":
      guard stateDirectory == nil else { throw UsageError(message: "Duplicate --state-dir") }
      let raw = try value(for: "--state-dir")
      guard isAbsolute(raw) else {
        throw UsageError(message: "--state-dir requires an absolute path")
      }
      stateDirectory = raw
    case "--force":
      guard !force else { throw UsageError(message: "Duplicate --force") }
      force = true
    case "--set-default":
      guard !setDefault else { throw UsageError(message: "Duplicate --set-default") }
      setDefault = true
    case "--remote":
      guard remote == nil else { throw UsageError(message: "Duplicate --remote") }
      let raw = try value(for: "--remote")
      try validateRemoteName(raw)
      remote = raw
    case "--incus":
      guard incusOverride == nil else { throw UsageError(message: "Duplicate --incus") }
      let raw = try value(for: "--incus")
      guard isAbsolute(raw) else {
        throw UsageError(message: "--incus requires an absolute path")
      }
      incusOverride = raw
    default:
      if token.hasPrefix("-") { throw UsageError(message: "Unknown flag \(token)") }
      positionals.append(token)
    }
    index += 1
  }
  let command: Command
  if positionals == ["runtime", "status"] {
    command = .runtimeStatus
  } else if positionals == ["runtime", "start"] {
    command = .runtimeStart
  } else if positionals == ["runtime", "stop"] {
    command = .runtimeStop(force: force)
  } else if positionals == ["runtime", "restart"] {
    command = .runtimeRestart
  } else if positionals == ["doctor"] {
    command = .doctor
  } else if positionals == ["client", "setup"] {
    command = .clientSetup(
      remote: remote ?? MacusCLI.defaultRemoteName, setDefault: setDefault, incus: incusOverride)
  } else if positionals == ["list"] || positionals.first == "show" {
    throw UsageError(
      message:
        "Unknown command. Workload operations belong to the standard incus client. Run macus --help"
    )
  } else {
    throw UsageError(
      message:
        "Unknown command. Workload operations belong to the standard incus client. Run macus --help"
    )
  }
  if force, case .runtimeStop = command {
  } else if force {
    throw UsageError(message: "--force is only valid with runtime stop")
  }
  if remote != nil || setDefault || incusOverride != nil {
    if case .clientSetup = command {
    } else {
      throw UsageError(
        message: "--remote, --set-default and --incus are only valid with client setup")
    }
  }
  return Invocation(
    stateDirectory: stateDirectory, json: json, timeout: timeout, command: command)
}

private func execute(
  _ command: Command, directory: URL, timeout: Int, json: Bool, environment: [String: String],
  transport: any LocalHTTPTransport, runner: any LocalCommandRunner, streams: MacusStreams
) async throws {
  switch command {
  case .runtimeStatus:
    let response = try await control(
      "GET", "/v1/runtime/status", Data(), directory: directory, timeout: timeout,
      transport: transport)
    try emitSuccess(response.body, json: json, streams: streams, human: runtimeText)
  case .runtimeStart:
    let response = try await control(
      "POST", "/v1/runtime/start", Data(), directory: directory, timeout: timeout,
      transport: transport)
    try emitSuccess(response.body, json: json, streams: streams, human: runtimeText)
  case .runtimeStop(let force):
    let response = try await control(
      "POST", "/v1/runtime/stop", try jsonData(["force": force]), directory: directory,
      timeout: timeout, transport: transport)
    try emitSuccess(response.body, json: json, streams: streams, human: runtimeText)
  case .runtimeRestart:
    let response = try await control(
      "POST", "/v1/runtime/restart", Data(), directory: directory, timeout: timeout,
      transport: transport)
    try emitSuccess(response.body, json: json, streams: streams, human: runtimeText)
  case .clientSetup(let remote, let setDefault, let incus):
    try await clientSetup(
      remote: remote, setDefault: setDefault, incusOverride: incus, directory: directory,
      timeout: timeout, json: json, environment: environment, transport: transport, runner: runner,
      streams: streams)
  case .doctor:
    try await doctor(
      directory: directory, timeout: timeout, json: json, transport: transport, streams: streams)
  }
}

private func control(
  _ method: String, _ path: String, _ body: Data, directory: URL, timeout: Int,
  transport: any LocalHTTPTransport
) async throws -> LocalHTTPResponse {
  let socket = try socketURL(directory.appendingPathComponent("runtime.sock"))
  return try await send(
    socket: socket, method: method, path: path, body: body, timeout: timeout, transport: transport)
}

private func clientSetup(
  remote: String, setDefault: Bool, incusOverride: String?, directory: URL, timeout: Int,
  json: Bool, environment: [String: String], transport: any LocalHTTPTransport,
  runner: any LocalCommandRunner, streams: MacusStreams
) async throws {
  if let incusOverride {
    guard FileManager.default.isExecutableFile(atPath: incusOverride) else {
      throw RuntimeError(.invalidConfiguration, "--incus must be an executable file")
    }
  }
  let status = try await readyStatus(
    directory: directory, timeout: timeout, transport: transport, command: "client setup")
  let socket = URL(fileURLWithPath: status.incusSocket)
  try validatePrivateUnixSocket(socket)
  let resolved = try await resolveIncus(
    override: incusOverride, environment: environment, timeout: timeout, runner: runner,
    streams: streams)
  let address = "unix:\(socket.path)"
  let previousDefault = try await incusDefault(
    resolved.executable, environment: environment, timeout: timeout, runner: runner)
  let remotes = try await incusRemotes(
    resolved.executable, environment: environment, timeout: timeout, runner: runner)
  if let existing = remotes[remote] {
    guard addressesMatch(existing, socket.path) else {
      throw RuntimeError(
        .conflict,
        "Remote \(remote) already points at a different address. macus client setup does not overwrite it."
      )
    }
  } else {
    try await requireSuccess(
      executable: resolved.executable, arguments: ["remote", "add", remote, address],
      environment: environment, timeout: timeout, runner: runner,
      failure: "incus remote add failed")
  }
  var selectedDefault = previousDefault
  if setDefault {
    try await requireSuccess(
      executable: resolved.executable, arguments: ["remote", "switch", remote],
      environment: environment, timeout: timeout, runner: runner,
      failure: "incus remote switch failed")
    selectedDefault = remote
  } else if let previousDefault {
    let current = try await incusDefault(
      resolved.executable, environment: environment, timeout: timeout, runner: runner)
    if current != previousDefault {
      try await requireSuccess(
        executable: resolved.executable, arguments: ["remote", "switch", previousDefault],
        environment: environment, timeout: timeout, runner: runner,
        failure: "Cannot restore the previous default remote")
    }
    selectedDefault = previousDefault
  }
  try await requireSuccess(
    executable: resolved.executable, arguments: ["list", "\(remote):"],
    environment: environment, timeout: timeout, runner: runner,
    failure: "incus list could not use the registered remote")
  let result: [String: Any] = [
    "address": address,
    "connected": true,
    "default": selectedDefault == remote,
    "incus": resolved.executable,
    "installed": resolved.installed,
    "remote": remote,
  ]
  if json {
    streams.writeOutput(try jsonText(result))
  } else {
    streams.writeOutput(renderObject(result))
  }
}

private struct ResolvedIncus {
  var executable: String
  var installed: Bool
}

private func resolveIncus(
  override: String?, environment: [String: String], timeout: Int, runner: any LocalCommandRunner,
  streams: MacusStreams
) async throws -> ResolvedIncus {
  if let override { return ResolvedIncus(executable: override, installed: false) }
  if let found = executable(named: "incus", path: environment["PATH"] ?? "") {
    return ResolvedIncus(executable: found, installed: false)
  }
  guard let brew = brewExecutable(environment: environment) else {
    throw RuntimeError(
      .unavailable,
      "Incus CLI was not found on PATH and Homebrew is not installed. Install Homebrew from https://brew.sh, then rerun macus client setup. macus does not install Homebrew."
    )
  }
  if let existing = try await installedIncus(
    brew: brew, environment: environment, timeout: timeout, runner: runner)
  {
    return ResolvedIncus(executable: existing, installed: false)
  }
  streams.writeError(
    "macus: Incus CLI not found; installing official Homebrew formula incus\n")
  var brewEnvironment = environment
  if brewEnvironment["HOMEBREW_NO_AUTO_UPDATE"] == nil {
    brewEnvironment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
  }
  let install = try await runner.run(
    executable: brew, arguments: ["install", "incus"], environment: brewEnvironment,
    timeout: timeout)
  if !install.stderr.isEmpty {
    let progress = String(decoding: install.stderr, as: UTF8.self)
    streams.writeError(terminalSafe(String(progress.prefix(4_000))))
    if !progress.hasSuffix("\n") { streams.writeError("\n") }
  }
  guard install.status == 0 else {
    throw RuntimeError(.io, "Homebrew install of incus failed")
  }
  guard
    let installed = try await installedIncus(
      brew: brew, environment: brewEnvironment,
      timeout: timeout, runner: runner)
  else {
    throw RuntimeError(
      .unavailable, "Homebrew installed incus but the executable was not found under its prefix")
  }
  return ResolvedIncus(executable: installed, installed: true)
}

private func installedIncus(
  brew: String, environment: [String: String], timeout: Int, runner: any LocalCommandRunner
) async throws -> String? {
  for arguments in [["--prefix"], ["--prefix", "incus"]] {
    let result = try await runner.run(
      executable: brew, arguments: arguments, environment: environment, timeout: timeout)
    guard result.status == 0,
      let prefix = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines), isAbsolute(prefix)
    else { continue }
    let candidate = URL(fileURLWithPath: prefix).appendingPathComponent("bin/incus").path
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}

private func brewExecutable(environment: [String: String]) -> String? {
  if let found = executable(named: "brew", path: environment["PATH"] ?? "") { return found }
  guard environment["MACUS_BREW_FALLBACK"] != "0" else { return nil }
  for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}

private func executable(named name: String, path: String) -> String? {
  for directory in path.split(separator: ":") where !directory.isEmpty {
    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
  }
  return nil
}

private func incusRemotes(
  _ executable: String, environment: [String: String], timeout: Int, runner: any LocalCommandRunner
) async throws -> [String: [String]] {
  let result = try await requireSuccess(
    executable: executable, arguments: ["remote", "list", "--format", "json"],
    environment: environment, timeout: timeout, runner: runner, failure: "incus remote list failed"
  )
  guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
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
  _ executable: String, environment: [String: String], timeout: Int, runner: any LocalCommandRunner
) async throws -> String? {
  let result = try await runner.run(
    executable: executable, arguments: ["remote", "get-default"], environment: environment,
    timeout: timeout)
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
  executable: String, arguments: [String], environment: [String: String], timeout: Int,
  runner: any LocalCommandRunner, failure: String
) async throws -> LocalCommandResult {
  let result = try await runner.run(
    executable: executable, arguments: arguments, environment: environment, timeout: timeout)
  guard result.status == 0 else {
    let detail = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let suffix = detail.isEmpty ? "" : ": \(detail.prefix(500))"
    throw RuntimeError(.io, "\(failure)\(suffix)")
  }
  return result
}

private func addressesMatch(_ stored: [String], _ socketPath: String) -> Bool {
  stored.contains { unixSocketPath($0) == socketPath }
}

private func unixSocketPath(_ address: String) -> String? {
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

private func validateRemoteName(_ name: String) throws {
  guard let first = name.utf8.first, (1...63).contains(name.utf8.count),
    isASCIIAlphanumeric(first),
    name.utf8.dropFirst().allSatisfy({ isRemoteByte($0) }),
    name != ".", name != ".."
  else { throw UsageError(message: "--remote must be a single name without path characters") }
}

private func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
  (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
}

private func isRemoteByte(_ byte: UInt8) -> Bool {
  isASCIIAlphanumeric(byte) || byte == 45 || byte == 46 || byte == 95
}

private func doctor(
  directory: URL, timeout: Int, json: Bool, transport: any LocalHTTPTransport, streams: MacusStreams
) async throws {
  let socket = try socketURL(directory.appendingPathComponent("runtime.sock"))
  let statusResponse = try await send(
    socket: socket, method: "GET", path: "/v1/runtime/status", body: Data(), timeout: timeout,
    transport: transport)
  let status = try jsonObject(statusResponse.body)
  var capabilities: [String: Any]?
  var health: [String: Any]?
  if let response = try? await send(
    socket: socket, method: "GET", path: "/v1/runtime/capabilities", body: Data(), timeout: timeout,
    transport: transport)
  {
    capabilities = try? jsonObject(response.body)
  }
  if let response = try? await send(
    socket: socket, method: "GET", path: "/v1/runtime/health", body: Data(), timeout: timeout,
    transport: transport)
  {
    health = try? jsonObject(response.body)
  }
  let report: [String: Any] = [
    "capabilities": capabilities ?? NSNull(),
    "health": health ?? NSNull(),
    "status": status,
  ]
  if json {
    streams.writeOutput(try jsonText(report))
  } else {
    streams.writeOutput(doctorText(status: status, capabilities: capabilities, health: health))
  }
  if let error = readinessError(status: status, capabilities: capabilities, health: health) {
    throw error
  }
}

private struct ReadyStatus {
  let apiVersion: Int
  let state: String
  let incusSocket: String
}

private func readyStatus(
  directory: URL, timeout: Int, transport: any LocalHTTPTransport, command: String
) async throws -> ReadyStatus {
  let response = try await control(
    "GET", "/v1/runtime/status", Data(), directory: directory, timeout: timeout,
    transport: transport)
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
  return ReadyStatus(apiVersion: api, state: state, incusSocket: incus)
}

private func readinessError(
  status: [String: Any], capabilities: [String: Any]?, health: [String: Any]?
) -> RuntimeError? {
  let state = jsonString(status["state"]) ?? "unknown"
  if jsonInt(status["api_version"]) != 1 {
    return RuntimeError(
      .invalidConfiguration,
      "Incompatible runtime API version. This macus client supports API version 1.")
  }
  if state != "ready" {
    return RuntimeError(
      .unavailable,
      "Runtime is \(state) and not ready. macus doctor does not start or repair the VM; run macus runtime start to boot it."
    )
  }
  if jsonBool(capabilities?["supported"]) != true {
    return RuntimeError(
      .unavailable,
      "Host virtualization is not supported. macus doctor does not change host configuration."
    )
  }
  if jsonInt(health?["protocol_version"]) != 1 {
    return RuntimeError(
      .unavailable,
      "Guest health protocol is unavailable or incompatible. macus doctor does not repair the guest."
    )
  }
  return nil
}

private func send(
  socket: URL, method: String, path: String, body: Data, timeout: Int,
  transport: any LocalHTTPTransport
) async throws -> LocalHTTPResponse {
  let response = try await transport.request(
    socket: socket, method: method, path: path, body: body, timeout: timeout)
  guard (200...299).contains(response.status) else {
    throw responseFailure(status: response.status, body: response.body)
  }
  return response
}

private func socketURL(_ url: URL) throws -> URL {
  guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count < 104 else {
    throw RuntimeError(
      .invalidConfiguration, "Unix socket path exceeds 103 bytes; choose a shorter state directory")
  }
  return url
}

private func responseFailure(status: Int, body: Data) -> RuntimeError {
  if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
    let error = object["error"] as? [String: Any], let code = jsonString(error["code"]),
    let message = jsonString(error["message"]), let parsed = RuntimeError.Code(rawValue: code)
  {
    return RuntimeError(parsed, message)
  }
  let incus = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
    .flatMap { jsonString($0["error"]) }
  let message = incus ?? "Local API request failed with HTTP \(status)"
  return RuntimeError(code(for: status), message)
}

private func code(for status: Int) -> RuntimeError.Code {
  switch status {
  case 400: .invalidRequest
  case 404: .notFound
  case 409: .conflict
  case 408, 504: .timeout
  case 503: .unavailable
  default: .io
  }
}

private func emitSuccess(
  _ body: Data, json: Bool, streams: MacusStreams, human: ([String: Any]) -> String
) throws {
  let object = try jsonObject(body)
  streams.writeOutput(json ? try jsonText(object) : human(object))
}

private func emit(_ error: RuntimeError, json: Bool, streams: MacusStreams) {
  if json,
    let text = try? jsonText(["error": ["code": error.code.rawValue, "message": error.message]])
  {
    streams.writeError(text)
    return
  }
  streams.writeError("macus: \(terminalSafe(error.message))\n")
}

private func runtimeText(_ object: [String: Any]) -> String {
  var lines = ["outer runtime"]
  for key in ["api_version", "state", "incus_socket", "uptime_seconds", "last_error"] {
    lines.append("\(key): \(renderScalar(object[key]))")
  }
  return lines.joined(separator: "\n") + "\n"
}

private func doctorText(
  status: [String: Any], capabilities: [String: Any]?, health: [String: Any]?
) -> String {
  var lines = ["outer runtime", renderObject(status).trimmingCharacters(in: .newlines)]
  lines.append("capabilities")
  if let capabilities {
    lines.append(renderObject(capabilities).trimmingCharacters(in: .newlines))
  } else {
    lines.append("unavailable")
  }
  lines.append("guest health")
  if let health {
    lines.append(renderObject(health).trimmingCharacters(in: .newlines))
  } else {
    lines.append("unavailable")
  }
  return lines.joined(separator: "\n") + "\n"
}

private func renderObject(_ object: [String: Any]) -> String {
  object.keys.sorted().map { key in
    "\(terminalSafe(key)): \(renderScalar(object[key]))\n"
  }.joined()
}

private func renderScalar(_ value: Any?) -> String {
  guard let value, !(value is NSNull) else { return "null" }
  if let text = value as? String { return terminalSafe(text) }
  if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
    return number.boolValue ? "true" : "false"
  }
  if let number = value as? NSNumber { return terminalSafe(number.stringValue) }
  if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
    let text = String(data: data, encoding: .utf8)
  {
    return terminalSafe(text)
  }
  return terminalSafe(String(describing: value))
}

func terminalSafe(_ value: String) -> String {
  var output = ""
  for scalar in value.unicodeScalars {
    if scalar.properties.generalCategory == .control || scalar.value == 127 {
      output += String(format: "\\u{%04X}", scalar.value)
    } else {
      output.unicodeScalars.append(scalar)
    }
  }
  return output
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
  do {
    let value = try JSONSerialization.jsonObject(with: data)
    guard let object = value as? [String: Any] else {
      throw RuntimeError(.io, "Malformed JSON object")
    }
    return object
  } catch let error as RuntimeError {
    throw error
  } catch {
    throw RuntimeError(.io, "Malformed JSON response")
  }
}

private func jsonData(_ object: [String: Any]) throws -> Data {
  do { return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) } catch {
    throw RuntimeError(.io, "Cannot encode JSON request")
  }
}

private func jsonText(_ value: Any) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  guard var text = String(data: data, encoding: .utf8) else {
    throw RuntimeError(.io, "Cannot encode JSON output")
  }
  if !text.hasSuffix("\n") { text.append("\n") }
  return text
}

private func jsonString(_ value: Any?) -> String? { value as? String }

private func jsonInt(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber, !isJSONBool(number) else { return nil }
  return number.intValue
}

private func jsonBool(_ value: Any?) -> Bool? {
  guard let number = value as? NSNumber, isJSONBool(number) else { return nil }
  return number.boolValue
}

private func isJSONBool(_ number: NSNumber) -> Bool {
  CFGetTypeID(number) == CFBooleanGetTypeID()
}
