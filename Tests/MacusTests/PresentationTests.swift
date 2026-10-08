import Darwin
import Foundation
import Testing

@testable import Macus

@Test func presentationPreservesMissingValuesControlsPathsAndShellArguments() {
  #expect(support(nil) == "Unavailable")
  #expect(support(false) == "Unsupported")
  #expect(humanDuration(72) == "1m 12s")
  #expect(humanBytes(134_217_728) == "128.0 MiB")
  #expect(
    shellCommand(["/tmp/client's bin/incus", "list", "macus:"])
      == "'/tmp/client'\"'\"'s bin/incus' list macus:")
  let capture = StartCapture()
  let presenter = HumanPresentation(streams: capture.streams, environment: ["TERM": "xterm"])
  presenter.runtime(
    [
      "state": "failed", "uptime_seconds": 72,
      "incus_socket": "/tmp/" + String(repeating: "long path/", count: 30) + "incus.sock",
      "last_error": "bad\nforged\u{1B}[2J",
    ], directory: URL(fileURLWithPath: "/tmp/state with 'quote"))
  #expect(capture.output.contains("1m 12s"))
  #expect(capture.output.contains(String(repeating: "long path/", count: 30)))
  #expect(capture.output.contains("bad\\u{000A}forged\\u{001B}[2J"))
  #expect(!capture.output.contains("\u{1B}"))
  #expect(capture.output.contains("'/tmp/state with '\"'\"'quote' runtime status"))
  #expect(capture.error.isEmpty)
}

@Test func nooraAdapterUsesSelectedStreamAndHasNoSignalOwnership() {
  let capture = StartCapture()
  var streams = capture.streams
  streams.stderrIsTTY = true
  let presenter = HumanPresentation(
    streams: streams, environment: ["TERM": "xterm", "NO_COLOR": ""], error: true)
  #expect(presenter.terminal.isInteractive)
  #expect(!presenter.terminal.isColored)
  if case .none = presenter.terminal.signalBehavior {} else { Issue.record("signal ownership") }
  presenter.failure("bad\rmessage", code: "io")
  #expect(capture.output.isEmpty)
  #expect(capture.error.contains("bad\\u{000D}message"))
  #expect(!capture.error.contains("\u{1B}"))
  let plain = HumanPresentation(streams: capture.streams, environment: ["TERM": "xterm"])
  #expect(!plain.terminal.isInteractive)
  #expect(!plain.terminal.isColored)
}

@Test func runtimeReportsRetainObservedStateAndSelectedCommands() async throws {
  for state in ["ready", "stopped", "starting", "failed", "absent"] {
    let server = try ScriptedSocket(name: "runtime.sock") { _, _, _ in
      var object = statusObject(state: state, incus: "/tmp/endpoint.sock")
      object["last_error"] = "useful failure"
      object["uptime_seconds"] = 72
      return mustJSON(200, object)
    }
    defer { server.stop() }
    for command in ["status", "start", "stop", "restart"] {
      let capture = StartCapture()
      let code = await MacusCLI.run(
        arguments: ["--state-dir", server.socket.directory.path, "runtime", command],
        streams: capture.streams)
      #expect(code == 0)
      #expect(capture.output.contains("Macus runtime: " + state.capitalized))
      #expect(capture.output.contains("/tmp/endpoint.sock"))
      #expect(capture.output.contains("1m 12s"))
      #expect(capture.output.contains("useful failure"))
      #expect(!capture.output.contains("uptime_seconds"))
      #expect(
        capture.output.contains(
          runtimeCommands(state: state, directory: server.socket.directory)[0]))
    }
  }
}

@Test func startupAndClientLayoutsHaveTruthfulOutcomesAndCompleteCommands() {
  let capture = StartCapture()
  let presentation = HumanPresentation(streams: capture.streams, environment: [:])
  presentation.startup(
    StartupResult(
      ready: true, connected: true, stateDirectory: "/tmp/state", remote: "demo",
      incus: "/tmp/client path/incus", installed: false, serviceOwnership: "foreground",
      capabilities: RuntimeCapabilities(
        host: HostCapabilities(supported: true, nestedVirtualization: true),
        health: GuestHealth(incusVersion: "6.0", apiExtensions: ["instance_oci"], kvm: false),
        nestingEnabled: true), nextCommands: ["'/tmp/client path/incus' list demo:"]))
  #expect(capture.output.contains("Macus is ready"))
  #expect(capture.output.contains("Closing the owning terminal"))
  #expect(capture.output.contains("System containers"))
  #expect(capture.output.contains("Unsupported"))
  #expect(capture.output.contains("  '/tmp/client path/incus' list demo:\n"))
  for installed in [true, false] {
    for selected in [true, false] {
      presentation.client(
        IncusSetupResult(
          address: "unix:/tmp/incus.sock", connected: true,
          isDefault: selected, executable: "/tmp/client path/incus", installed: installed,
          remote: "demo", onPath: false))
    }
  }
  #expect(capture.output.contains("Installed with Homebrew"))
  #expect(capture.output.contains("Reused existing client"))
  #expect(capture.output.contains("Existing selection preserved"))
  #expect(capture.output.contains("Default remote: Selected"))
}

@Test func doctorFixturesKeepHostAndWorkloadObservationsDistinct() async throws {
  for state in ["ready", "stopped", "failed", "unavailable", "incompatible"] {
    let server = try ScriptedSocket(name: "runtime.sock") { _, path, _ in
      if path == "/v1/runtime/status" {
        var status = statusObject(
          state: state == "incompatible" ? "ready" : state, incus: "/tmp/incus.sock")
        if state == "incompatible" { status["api_version"] = 2 }
        status["last_error"] = "retained runtime diagnosis"
        return mustJSON(200, status)
      }
      if state == "unavailable" || state == "stopped" || state == "failed" {
        return mustJSON(503, errorObject(code: "unavailable", message: "not ready"))
      }
      if path == "/v1/runtime/capabilities" {
        return mustJSON(
          200,
          [
            "supported": true, "nested_virtualization": true,
            "capabilities": [
              "system_containers": true, "oci": true, "vm": false,
              "nested_virtualization": true, "virtiofs": true,
            ],
          ])
      }
      return mustJSON(
        200,
        [
          "protocol_version": 1, "incus_version": "6.0", "kvm": false,
          "api_extensions": [String(repeating: "extension", count: 100)],
        ])
    }
    defer { server.stop() }
    let capture = StartCapture()
    let code = await MacusCLI.run(
      arguments: ["--state-dir", server.socket.directory.path, "doctor"], streams: capture.streams)
    #expect(code == (state == "ready" ? 0 : 1))
    #expect(
      capture.output.contains(state == "ready" ? "Macus is healthy" : "Macus needs attention"))
    #expect(capture.output.contains("retained runtime diagnosis"))
    for section in ["Runtime", "Host support", "Workload support", "Guest health"] {
      #expect(capture.output.contains(section))
    }
    #expect(!capture.output.contains("api_extensions"))
    #expect(capture.error.isEmpty)
    if state == "stopped" {
      #expect(
        capture.output.contains(
          "macus --state-dir " + server.socket.directory.path + " runtime start"))
      #expect(capture.output.contains("Unavailable"))
    }
    if state == "ready" {
      #expect(capture.output.contains("Host nesting"))
      #expect(capture.output.contains("Virtual machines"))
      #expect(capture.output.contains("Unsupported"))
    }
    #expect(server.requests().allSatisfy { $0.method == "GET" })
  }
}

@Test func hostCapabilitiesAcceptBothJSONPlacementsAndRejectIrrelevantFlags() async throws {
  let root = "/tmp/macus-readonly-" + String(UUID().uuidString.prefix(8))
  let environment = ["MACUS_STATE_DIR": root, "TERM": "dumb"]
  for arguments in [["capabilities", "--json"], ["--json", "capabilities"]] {
    let capture = StartCapture()
    #expect(
      await MacusCLI.run(arguments: arguments, environment: environment, streams: capture.streams)
        == 0)
    let object = try jsonObject(Data(capture.output.utf8))
    #expect(
      Set(object.keys)
        == Set([
          "platform", "architecture", "virtualization", "supported", "nested_virtualization",
          "virtiofs",
        ]))
    #expect(object["supported"] is Bool)
    #expect(capture.error.isEmpty)
  }
  let human = StartCapture()
  #expect(
    await MacusCLI.run(
      arguments: ["capabilities"], environment: environment, streams: human.streams) == 0)
  #expect(human.output.contains("Macus host capabilities"))
  #expect(human.output.contains("does not establish guest"))
  for flags in [
    ["--timeout", "1"], ["--state-dir", root], ["--force"], ["--remote", "demo"],
    ["--progress", "none"],
  ] {
    #expect(
      await MacusCLI.run(
        arguments: ["capabilities"] + flags, environment: environment,
        streams: StartCapture().streams) == 2)
  }
  #expect(!FileManager.default.fileExists(atPath: root))
}

@Test func documentedReportExamplesMatchFixturesAndCommandsParse() async throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let docs = try String(contentsOf: root.appendingPathComponent("docs/cli.md"), encoding: .utf8)
  let directory = URL(fileURLWithPath: "/tmp/macus-demo")
  let runtime = StartCapture()
  HumanPresentation(streams: runtime.streams, environment: [:]).runtime(
    [
      "state": "stopped", "uptime_seconds": 72, "incus_socket": "/tmp/macus-demo/incus.sock",
    ], directory: directory)
  #expect(docs.contains(runtime.output.trimmingCharacters(in: .newlines)))
  let startup = StartCapture()
  HumanPresentation(streams: startup.streams, environment: [:]).startup(
    StartupResult(
      ready: true, connected: true, stateDirectory: directory.path, remote: "macus",
      incus: "/opt/homebrew/bin/incus", installed: false, serviceOwnership: "foreground",
      nextCommands: ["incus list macus:"]))
  #expect(docs.contains(startup.output.trimmingCharacters(in: .newlines)))
  let client = StartCapture()
  HumanPresentation(streams: client.streams, environment: [:]).client(
    IncusSetupResult(
      address: "unix:/tmp/macus-demo/incus.sock", connected: true, isDefault: false,
      executable: "/opt/homebrew/bin/incus", installed: false, remote: "macus", onPath: true))
  #expect(docs.contains(client.output.trimmingCharacters(in: .newlines)))
  let temporary = "/tmp/macus-grammar-" + String(UUID().uuidString.prefix(8))
  for arguments in [
    ["start"], ["runtime", "status"], ["doctor", "--json"],
    ["capabilities", "--json"], ["--state-dir", temporary, "start", "--progress", "plain"],
    ["client", "setup", "--remote", "macus"],
  ] {
    let capture = StartCapture()
    let code = await MacusCLI.run(
      arguments: arguments,
      environment: [
        "MACUS_STATE_DIR": temporary, "MACUS_BREW_FALLBACK": "0", "PATH": "/usr/bin:/bin",
      ],
      streams: capture.streams,
      overrides: StartupOverrides(
        capabilities: { HostCapabilities(supported: false, nestedVirtualization: false) },
        installSignals: false))
    #expect(code != 2)
  }
  #expect(!FileManager.default.fileExists(atPath: temporary))
}

@Test func copyableCommandsRoundTripUnsafeArgumentsWithoutTerminalControls() async throws {
  let values = [
    "/tmp/path with 'quotes'", "/tmp/dollar$(false)`false`", "/tmp/tab\tand\u{1B}[2J",
    "/tmp/\u{202E}path", "/tmp/back\\slash",
  ]
  for value in values {
    let command = shellCommand(["/usr/bin/printf", "%s", value])
    #expect(!command.contains("\u{1B}"))
    #expect(!command.contains("\t"))
    let result = try await ProcessCommandRunner().run(
      executable: "/bin/zsh", arguments: ["-c", command], environment: [:], timeout: 3)
    #expect(result.status == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == value)
  }
}

@Test func doctorMissingLiveObservationsNeverBecomeUnsupportedAndRetainsDiagnostic() {
  let capture = StartCapture()
  let presentation = HumanPresentation(streams: capture.streams, environment: [:])
  presentation.doctor(
    status: ["state": "ready", "api_version": 1], capabilities: nil,
    health: nil, directory: URL(fileURLWithPath: "/tmp/state"),
    error: RuntimeError(.unavailable, "Host virtualization is not supported"),
    observations: ["host": "fixture capability error\u{1B}[2J", "guest": "fixture health error"])
  #expect(capture.output.contains("Host support observation is unavailable"))
  #expect(!capture.output.contains("not supported"))
  #expect(!capture.output.contains("Unsupported"))
  #expect(capture.output.contains("fixture capability error\\u{001B}[2J"))
  #expect(capture.output.contains("fixture health error"))
  let unavailable = StartCapture()
  HumanPresentation(streams: unavailable.streams, environment: [:]).doctor(
    status: ["state": "stopped", "api_version": 1],
    capabilities: [
      "supported": true, "incus": ["available": false],
      "capabilities": [
        "vm": false, "system_containers": false, "oci": false,
        "nested_virtualization": true, "virtiofs": true,
      ],
    ], health: nil,
    directory: URL(fileURLWithPath: "/tmp/state"), error: RuntimeError(.unavailable, "Stopped"))
  #expect(unavailable.output.contains("Host nesting"))
  #expect(!unavailable.output.contains("Unsupported"))
  #expect(unavailable.output.contains("Workload support\n  Status: Unavailable"))
}
