import Foundation

public struct MacusStreams: Sendable {
  public var writeOutput: @Sendable (String) -> Void
  public var writeError: @Sendable (String) -> Void

  public var stdoutIsTTY = false
  public var stderrIsTTY = false

  public static let standard = MacusStreams(
    writeOutput: { text in
      try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    },
    writeError: { text in
      try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    },
    stdoutIsTTY: isatty(STDOUT_FILENO) == 1,
    stderrIsTTY: isatty(STDERR_FILENO) == 1
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
  public static let startTimeout = 1_800

  public static func run(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    transport: any LocalHTTPTransport = UnixHTTPClient(),
    streams: MacusStreams = .standard
  ) async -> Int32 {
    await run(
      arguments: arguments, environment: environment, transport: transport, streams: streams,
      overrides: StartupOverrides())
  }

  static func run(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    transport: any LocalHTTPTransport = UnixHTTPClient(),
    streams: MacusStreams = .standard,
    overrides: StartupOverrides
  ) async -> Int32 {
    let json = requestsJSON(arguments)
    do {
      if arguments.isEmpty || arguments == ["--help"] {
        streams.writeOutput(helpText)
        return 0
      }
      if arguments.first == "serve" {
        try await Daemon.run(arguments: arguments, environment: environment, streams: streams)
        return 0
      }
      let invocation = try parse(arguments)
      let directory: URL
      if case .capabilities = invocation.command {
        directory = URL(fileURLWithPath: "/")
      } else {
        directory = try stateDirectory(flag: invocation.stateDirectory, environment: environment)
      }
      let timeout = invocation.timeout ?? defaultTimeout(invocation.command)
      try await execute(
        invocation.command, directory: directory, timeout: timeout, json: invocation.json,
        environment: environment, transport: transport, runner: ProcessCommandRunner(),
        streams: streams, overrides: overrides)
      return 0
    } catch let error as UsageError {
      emit(
        RuntimeError(.invalidRequest, error.message), json: json, streams: streams,
        environment: environment)
      return 2
    } catch let error as StartupInterrupted {
      emitInterrupted(
        error, json: json, streams: streams, environment: environment,
        commands: recoveryCommands(arguments: arguments, environment: environment))
      return 130
    } catch is ReportedDiagnosis {
      return 1
    } catch let error as RuntimeError {
      emit(
        error, json: json, streams: streams, environment: environment,
        commands: recoveryCommands(arguments: arguments, environment: environment))
      return arguments.first == "serve" && error.code == .invalidRequest ? 2 : 1
    } catch {
      emit(
        RuntimeError(.io, error.localizedDescription), json: json, streams: streams,
        environment: environment)
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

    Startup:
      start [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH] [--progress auto|plain|none]
        Prepare the appliance, wait for readiness and connect the Incus client.

    Inspection:
      runtime status    Observe the outer runtime.
      doctor            Diagnose live runtime, host and guest health.
      capabilities      Report host support; add --json for machine output.

    Lifecycle:
      runtime start     Boot an existing appliance.
      runtime stop [--force]
      runtime restart
      serve [--state-dir ABSOLUTE_PATH]    Own the daemon in this terminal.

    Client:
      client setup [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH]

    Common examples:
      macus start
      macus runtime status
      macus doctor --json
      macus capabilities --json
      macus --state-dir /tmp/macus-demo start --progress plain
      macus client setup --remote macus

    Options:
      --json            Machine results on stdout, errors on stderr.
      --progress auto|plain|none    Startup progress on stderr.
      --state-dir ABSOLUTE_PATH    Select existing or isolated state.
      --timeout SECONDS           Set a bounded deadline.

    start is the high-level first-use command. It prepares the pinned appliance,
    activates a per-user background service when needed, creates an absent runtime,
    waits for live Incus readiness, and registers the standard incus client. It does
    not install Homebrew or require sudo. serve, runtime, doctor and client setup remain
    explicit lower-level commands and do not download an appliance or activate a service.

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
    client setup (1...3600). macus start defaults to \(startTimeout) seconds, still within
    1...3600, and uses one deadline across download, boot, the expected kernel restart and
    client setup. A restart or Homebrew install may need a larger value.
    --progress auto animates only on an interactive terminal; plain and JSON avoid cursor
    escapes. --progress none suppresses progress. Exit status is 0 on success, 1 on
    operational failure, 2 on invalid arguments and 130 when start is interrupted.

    """
  }
}

private struct ReportedDiagnosis: Error {}

private struct UsageError: Error {
  let message: String
}

private enum Command {
  case capabilities
  case runtimeStatus
  case runtimeStart
  case runtimeStop(force: Bool)
  case runtimeRestart
  case doctor
  case clientSetup(remote: String, setDefault: Bool, incus: String?)
  case start(remote: String, setDefault: Bool, incus: String?, progress: ProgressSelection)
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
      || token == "--incus" || token == "--progress"
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
  case .start: MacusCLI.startTimeout
  case .capabilities, .runtimeStatus, .doctor: MacusCLI.readOnlyTimeout
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
  var progress: String?
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
    case "--progress":
      guard progress == nil else { throw UsageError(message: "Duplicate --progress") }
      let raw = try value(for: "--progress")
      guard ProgressSelection(rawValue: raw) != nil else {
        throw UsageError(message: "--progress must be auto, plain or none")
      }
      progress = raw
    default:
      if token.hasPrefix("-") { throw UsageError(message: "Unknown flag \(token)") }
      positionals.append(token)
    }
    index += 1
  }
  let command: Command
  if positionals == ["capabilities"] {
    guard stateDirectory == nil, timeout == nil else {
      throw UsageError(message: "capabilities accepts only --json")
    }
    command = .capabilities
  } else if positionals == ["runtime", "status"] {
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
  } else if positionals == ["start"] {
    command = .start(
      remote: remote ?? MacusCLI.defaultRemoteName, setDefault: setDefault, incus: incusOverride,
      progress: ProgressSelection(rawValue: progress ?? "auto") ?? .auto)
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
    switch command {
    case .clientSetup, .start: break
    default:
      throw UsageError(
        message: "--remote, --set-default and --incus are only valid with start and client setup")
    }
  }
  if progress != nil {
    if case .start = command {
    } else {
      throw UsageError(message: "--progress is only valid with start")
    }
  }
  return Invocation(
    stateDirectory: stateDirectory, json: json, timeout: timeout, command: command)
}

private func execute(
  _ command: Command, directory: URL, timeout: Int, json: Bool, environment: [String: String],
  transport: any LocalHTTPTransport, runner: any LocalCommandRunner, streams: MacusStreams,
  overrides: StartupOverrides
) async throws {
  let presentation = HumanPresentation(streams: streams, environment: environment)
  switch command {
  case .capabilities:
    let capabilities: HostCapabilities
    if let detect = overrides.capabilities {
      capabilities = await detect()
    } else {
      capabilities = await MainActor.run { CapabilityDetector.detect() }
    }
    let data = try JSON.encoder().encode(capabilities)
    if json {
      streams.writeOutput(String(decoding: data, as: UTF8.self) + "\n")
    } else {
      presentation.capabilities(try jsonObject(data))
    }
  case .runtimeStatus:
    let response = try await control(
      "GET", "/v1/runtime/status", Data(), directory: directory, timeout: timeout,
      transport: transport)
    if json {
      streams.writeOutput(try jsonText(jsonObject(response.body)))
    } else {
      presentation.runtime(try jsonObject(response.body), directory: directory)
    }
  case .runtimeStart:
    let response = try await control(
      "POST", "/v1/runtime/start", Data(), directory: directory, timeout: timeout,
      transport: transport)
    if json {
      streams.writeOutput(try jsonText(jsonObject(response.body)))
    } else {
      presentation.runtime(try jsonObject(response.body), directory: directory)
    }
  case .runtimeStop(let force):
    let response = try await control(
      "POST", "/v1/runtime/stop", try jsonData(["force": force]), directory: directory,
      timeout: timeout, transport: transport)
    if json {
      streams.writeOutput(try jsonText(jsonObject(response.body)))
    } else {
      presentation.runtime(try jsonObject(response.body), directory: directory)
    }
  case .runtimeRestart:
    let response = try await control(
      "POST", "/v1/runtime/restart", Data(), directory: directory, timeout: timeout,
      transport: transport)
    if json {
      streams.writeOutput(try jsonText(jsonObject(response.body)))
    } else {
      presentation.runtime(try jsonObject(response.body), directory: directory)
    }
  case .clientSetup(let remote, let setDefault, let incus):
    let result = try await IncusClientService(
      runner: overrides.runner ?? runner, streams: streams, environment: environment
    ).setup(
      remote: remote, setDefault: setDefault, incusOverride: incus, directory: directory,
      timeout: timeout, transport: transport)
    let object = clientResultObject(result)
    if json { streams.writeOutput(try jsonText(object)) } else { presentation.client(result) }
  case .doctor:
    try await doctor(
      directory: directory, timeout: timeout, json: json, transport: transport, streams: streams,
      presentation: presentation)
  case .start(let remote, let setDefault, let incus, let progress):
    try await runStart(
      directory: directory, remote: remote, setDefault: setDefault, incusOverride: incus,
      progress: progress, timeout: timeout, json: json, environment: environment,
      transport: transport, runner: runner, streams: streams, overrides: overrides)
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

private func clientResultObject(_ result: IncusSetupResult) -> [String: Any] {
  [
    "address": result.address,
    "connected": result.connected,
    "default": result.isDefault,
    "incus": result.executable,
    "installed": result.installed,
    "remote": result.remote,
  ]
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
  directory: URL, timeout: Int, json: Bool, transport: any LocalHTTPTransport,
  streams: MacusStreams,
  presentation: HumanPresentation
) async throws {
  let socket = try socketURL(directory.appendingPathComponent("runtime.sock"))
  let statusResponse = try await send(
    socket: socket, method: "GET", path: "/v1/runtime/status", body: Data(), timeout: timeout,
    transport: transport)
  let status = try jsonObject(statusResponse.body)
  var capabilities: [String: Any]?
  var health: [String: Any]?
  var observations: [String: String] = [:]
  do {
    let response = try await send(
      socket: socket, method: "GET", path: "/v1/runtime/capabilities",
      body: Data(), timeout: timeout, transport: transport)
    capabilities = try jsonObject(response.body)
  } catch {
    observations["host"] = (error as? RuntimeError)?.message ?? error.localizedDescription
  }
  do {
    let response = try await send(
      socket: socket, method: "GET", path: "/v1/runtime/health",
      body: Data(), timeout: timeout, transport: transport)
    health = try jsonObject(response.body)
  } catch {
    observations["guest"] = (error as? RuntimeError)?.message ?? error.localizedDescription
  }
  let report: [String: Any] = [
    "capabilities": capabilities ?? NSNull(),
    "health": health ?? NSNull(),
    "status": status,
  ]
  if json {
    streams.writeOutput(try jsonText(report))
  } else {
    presentation.doctor(
      status: status, capabilities: capabilities, health: health,
      directory: directory,
      error: readinessError(status: status, capabilities: capabilities, health: health),
      observations: observations)
  }
  if let error = readinessError(status: status, capabilities: capabilities, health: health) {
    if !json { throw ReportedDiagnosis() }
    throw error
  }
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

func responseFailure(status: Int, body: Data) -> RuntimeError {
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

func emitInterrupted(
  _ error: StartupInterrupted, json: Bool, streams: MacusStreams,
  environment: [String: String] = [:], commands: [String] = []
) {
  if json,
    let text = try? jsonText(["error": ["code": "interrupted", "message": error.message]])
  {
    streams.writeError(text)
    return
  }
  HumanPresentation(streams: streams, environment: environment, error: true).failure(
    error.message, code: "interrupted", commands: commands)
}

private func emit(
  _ error: RuntimeError, json: Bool, streams: MacusStreams,
  environment: [String: String], commands: [String] = []
) {
  if json,
    let text = try? jsonText(["error": ["code": error.code.rawValue, "message": error.message]])
  {
    streams.writeError(text)
    return
  }
  HumanPresentation(streams: streams, environment: environment, error: true).failure(
    error.message, code: error.code.rawValue,
    commands: error.code == .invalidRequest ? ["macus --help"] : commands)
}

private func recoveryCommands(arguments: [String], environment: [String: String]) -> [String] {
  guard let invocation = try? parse(arguments),
    let directory = try? MacusCLI.stateDirectory(
      flag: invocation.stateDirectory, environment: environment)
  else { return [] }
  if case .start = invocation.command {
    return [
      shellCommand(["macus", "--state-dir", directory.path, "runtime", "status"]),
      shellCommand(["macus", "--state-dir", directory.path, "runtime", "stop"]),
    ]
  }
  return []
}

func terminalSafe(_ value: String) -> String {
  var output = ""
  for scalar in value.unicodeScalars {
    if scalar.properties.generalCategory == .control || scalar.value == 127
      || (0x2028...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    {
      output += String(format: "\\u{%04X}", scalar.value)
    } else {
      output.unicodeScalars.append(scalar)
    }
  }
  return output
}

func jsonObject(_ data: Data) throws -> [String: Any] {
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

func jsonText(_ value: Any) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  guard var text = String(data: data, encoding: .utf8) else {
    throw RuntimeError(.io, "Cannot encode JSON output")
  }
  if !text.hasSuffix("\n") { text.append("\n") }
  return text
}

func jsonString(_ value: Any?) -> String? { value as? String }

func jsonInt(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber, !isJSONBool(number) else { return nil }
  return number.intValue
}

func jsonBool(_ value: Any?) -> Bool? {
  guard let number = value as? NSNumber, isJSONBool(number) else { return nil }
  return number.boolValue
}

private func isJSONBool(_ number: NSNumber) -> Bool {
  CFGetTypeID(number) == CFBooleanGetTypeID()
}
