import Darwin
import Foundation
import Noora

struct StreamPipeline: StandardPipelining {
  let write: @Sendable (String) -> Void
  func write(content: String) { write(content) }
}

/// No input, raw mode, or signal ownership: Macus owns cancellation and exit codes.
struct MacusTerminal: Terminaling {
  let descriptor: Int32
  let isInteractive: Bool
  let isColored: Bool
  let write: @Sendable (String) -> Void
  let width: (@Sendable () -> Int?)?
  var signalBehavior: SignalBehavior { .none }

  init(
    descriptor: Int32, isTTY: Bool, environment: [String: String],
    width: (@Sendable () -> Int?)? = nil, write: @escaping @Sendable (String) -> Void
  ) {
    self.descriptor = descriptor
    isInteractive =
      isTTY && environment["TERM"] != nil && environment["TERM"] != "dumb"
      && environment["TERM"] != ""
    isColored = isInteractive && environment["NO_COLOR"] == nil
    self.width = width
    self.write = write
  }

  func size() -> TerminalSize? {
    if let width {
      guard let columns = width(), columns > 0 else { return nil }
      return TerminalSize(rows: 24, columns: columns)
    }
    var value = winsize()
    guard ioctl(descriptor, UInt(TIOCGWINSZ), &value) == 0, value.ws_col > 0 else { return nil }
    return TerminalSize(rows: max(1, Int(value.ws_row)), columns: Int(value.ws_col))
  }
  func withoutCursor(_ body: () throws -> Void) rethrows {
    if isInteractive { write("\u{1B}[?25l") }
    defer { if isInteractive { write("\u{1B}[?25h") } }
    try body()
  }
  func inRawMode(_ body: @escaping () throws -> Void) rethrows { try body() }
  func readRawCharacter() -> Int32? { nil }
  func readCharacter() -> Character? { nil }
  func readRawCharacterNonBlocking() -> Int32? { nil }
  func readCharacterNonBlocking() -> Character? { nil }
}

/// Static Noora tables must append scrollback, never use its cursor-moving renderer.
final class ScrollbackRenderer: Rendering {
  func render(_ input: String, standardPipeline: any StandardPipelining) {
    standardPipeline.write(content: input + (input.hasSuffix("\n") ? "" : "\n"))
  }
}

struct HumanPresentation {
  let noora: Noora
  let terminal: MacusTerminal

  init(
    streams: MacusStreams, environment: [String: String], error: Bool = false
  ) {
    let write = error ? streams.writeError : streams.writeOutput
    terminal = MacusTerminal(
      descriptor: error ? STDERR_FILENO : STDOUT_FILENO,
      isTTY: error ? streams.stderrIsTTY : streams.stdoutIsTTY,
      environment: environment, write: write)
    noora = Noora(
      terminal: terminal,
      standardPipelines: StandardPipelines(
        output: StreamPipeline(write: write), error: StreamPipeline(write: write)))
  }

  func text(_ value: String) { noora.passthrough(TerminalText(stringLiteral: value)) }
  func heading(_ value: String) { noora.passthrough("\(.primary(value))\n") }
  func field(_ label: String, _ value: String?) {
    text("  \(label): \(terminalSafe(value ?? "Unavailable"))\n")
  }
  func section(_ title: String, rows: [[String]]) {
    heading("\n" + title)
    // Noora's table cells truncate at terminal width. Only bounded support rows go here.
    if let width = terminal.size()?.columns, width < 60 {
      for row in rows where row.count == 2 { field(row[0], row[1]) }
    } else {
      noora.table(headers: ["Observation", "Status"], rows: rows, renderer: ScrollbackRenderer())
    }
  }
  func next(_ commands: [String]) {
    guard !commands.isEmpty else { return }
    heading("\nNext steps")
    for command in commands { text("  \(terminalSafe(command))\n") }
  }
  func failure(_ message: String, code: String, commands: [String] = []) {
    noora.error(.alert("\(.danger("Macus failed (\(code))"))"))
    text("  \(terminalSafe(message))\n")
    next(commands)
  }

  func runtime(_ object: [String: Any], directory: URL) {
    let state = jsonString(object["state"]) ?? "unavailable"
    heading("Macus runtime: \(terminalSafe(state.capitalized))")
    runtimeFields(object, directory: directory)
    next(runtimeCommands(state: state, directory: directory))
  }
  func runtimeFields(_ object: [String: Any], directory: URL) {
    heading("\nRuntime")
    field("Status", jsonString(object["state"])?.capitalized)
    field("Uptime", jsonInt(object["uptime_seconds"]).map(humanDuration))
    field("Control socket", directory.appendingPathComponent("runtime.sock").path)
    field("Incus socket", jsonString(object["incus_socket"]))
    if let error = jsonString(object["last_error"]), !error.isEmpty { field("Last error", error) }
  }
  func host(_ object: [String: Any], title: String = "Host support") {
    section(
      title,
      rows: [
        ["Apple virtualization", support(jsonBool(object["supported"]))],
        ["Host nesting", support(jsonBool(object["nested_virtualization"]))],
        ["File sharing", support(jsonBool(object["virtiofs"]))],
      ])
    field("Platform", jsonString(object["platform"]))
    field("Architecture", jsonString(object["architecture"]))
    field("Virtualization", jsonString(object["virtualization"]))
  }
  func capabilities(_ object: [String: Any]) {
    heading("Macus host capabilities")
    host(object)
    text("\nHost support does not establish guest or workload readiness.\n")
    next(["macus start", "macus capabilities --json"])
  }
  func workload(_ object: [String: Any]?) {
    guard let object else {
      heading("\nWorkload support")
      field("Status", nil)
      return
    }
    section(
      "Workload support",
      rows: [
        ["System containers", support(jsonBool(object["system_containers"]))],
        ["OCI containers", support(jsonBool(object["oci"]))],
        ["Virtual machines", support(jsonBool(object["vm"]))],
        ["Nested virtualization", support(jsonBool(object["nested_virtualization"]))],
        ["File sharing", support(jsonBool(object["virtiofs"]))],
      ])
  }
  func doctor(
    status: [String: Any], capabilities: [String: Any]?, health: [String: Any]?,
    directory: URL, error: RuntimeError?, observations: [String: String] = [:]
  ) {
    if error == nil {
      noora.success(.alert("Macus is healthy"))
    } else if jsonString(status["state"]) == "failed" {
      noora.error(.alert("Macus needs attention"))
    } else {
      noora.warning(.alert("Macus needs attention"))
    }
    runtimeFields(status, directory: directory)
    if let capabilities {
      var hostObservations = capabilities
      let features = capabilities["capabilities"] as? [String: Any]
      for key in ["nested_virtualization", "virtiofs"] where hostObservations[key] == nil {
        hostObservations[key] = features?[key]
      }
      host(hostObservations)
    } else {
      heading("\nHost support")
      field("Status", nil)
    }
    if let detail = observations["host"] { field("Diagnostic", detail) }
    let liveIncus = capabilities?["incus"] as? [String: Any]
    workload(
      jsonBool(liveIncus?["available"]) == false
        ? nil : capabilities?["capabilities"] as? [String: Any])
    heading("\nGuest health")
    if let health {
      field("Protocol", jsonInt(health["protocol_version"]).map(String.init))
      field("Incus version", jsonString(health["incus_version"]))
      field("Guest KVM", support(jsonBool(health["kvm"])))
    } else {
      field("Status", nil)
    }
    if let detail = observations["guest"] { field("Diagnostic", detail) }
    if let error {
      let diagnosis =
        jsonInt(status["api_version"]) == 1 && jsonString(status["state"]) == "ready"
          && jsonBool(capabilities?["supported"]) == nil
        ? "Host support observation is unavailable." : error.message
      field("Diagnosis", diagnosis)
    }
    let state = jsonString(status["state"]) ?? "unavailable"
    let compatible = jsonInt(status["api_version"]) == 1
    next(compatible ? runtimeCommands(state: state, directory: directory) : ["macus --help"])
  }
  func client(_ result: IncusSetupResult) {
    heading(result.connected ? "Incus client is connected" : "Incus client is unavailable")
    heading("\nClient")
    field("Connection", result.connected ? "Connected" : "Unavailable")
    field("Remote", result.remote)
    field("Endpoint", result.address)
    field("Executable", result.executable)
    field("Installation", result.installed ? "Installed with Homebrew" : "Reused existing client")
    field("Default remote", result.isDefault ? "Selected" : "Existing selection preserved")
    next([shellCommand([result.onPath ? "incus" : result.executable, "list", result.remote + ":"])])
  }
  func startup(_ result: StartupResult) {
    heading(result.ready && result.connected ? "Macus is ready" : "Macus needs attention")
    heading("\nRuntime")
    field("Status", result.observedState?.capitalized ?? (result.ready ? "Ready" : "Unavailable"))
    field("State directory", result.stateDirectory)
    heading("\nClient")
    field("Connection", result.connected ? "Connected" : "Unavailable")
    field("Remote", result.remote)
    field("Executable", result.incus)
    field("Installation", result.installed ? "Installed with Homebrew" : "Reused existing client")
    heading("\nService")
    field("Ownership", result.serviceOwnership.capitalized)
    if let label = result.serviceLabel { field("Label", label) }
    if result.serviceOwnership == "foreground" {
      text("  Closing the owning terminal stops the daemon.\n")
    }
    if let capabilities = result.capabilities,
      let data = try? JSON.encoder().encode(capabilities), let object = try? jsonObject(data)
    {
      workload(object["capabilities"] as? [String: Any])
    }
    if let guidance = result.pathGuidance { field("Client path guidance", guidance) }
    next(result.nextCommands)
  }
}

func support(_ value: Bool?) -> String {
  guard let value else { return "Unavailable" }
  return value ? "Supported" : "Unsupported"
}

func humanDuration(_ seconds: Int) -> String {
  let value = max(0, seconds)
  if value >= 3_600 { return "\(value / 3_600)h \((value % 3_600) / 60)m" }
  if value >= 60 { return "\(value / 60)m \(value % 60)s" }
  return "\(value)s"
}

func humanBytes(_ bytes: Int64) -> String {
  let value = Double(max(0, bytes))
  for (unit, size) in [("GiB", 1_073_741_824.0), ("MiB", 1_048_576.0), ("KiB", 1_024.0)] {
    if value >= size { return String(format: "%.1f %@", value / size, unit) }
  }
  return "\(max(0, bytes)) bytes"
}

func shellCommand(_ arguments: [String]) -> String {
  arguments.map(shellQuote).joined(separator: " ")
}
func shellQuote(_ value: String) -> String {
  if terminalSafe(value) != value {
    var escaped = ""
    for scalar in value.unicodeScalars {
      if terminalSafe(String(scalar)) != String(scalar) {
        escaped += String(scalar).utf8.map { String(format: "\\x%02X", $0) }.joined()
      } else if scalar == "\\" {
        escaped += "\\\\"
      } else if scalar == "'" {
        escaped += "\\'"
      } else {
        escaped.unicodeScalars.append(scalar)
      }
    }
    return "$'" + escaped + "'"
  }

  if !value.isEmpty
    && value.utf8.allSatisfy({
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || Array("/._:-".utf8).contains($0)
    })
  {
    return value
  }
  return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
func runtimeCommands(state: String, directory: URL) -> [String] {
  let command: [String]
  switch state {
  case "absent": command = ["start"]
  case "stopped": command = ["runtime", "start"]
  case "ready": command = ["doctor"]
  default: command = ["runtime", "status"]
  }
  return [shellCommand(["macus", "--state-dir", directory.path] + command)]
}
