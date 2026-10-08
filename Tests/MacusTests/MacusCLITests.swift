import Foundation
import Testing

@testable import Macus

@Test func macusHelpAndGrammarExitBeforeNetworking() async throws {
  for arguments in [[String](), ["--help"]] {
    let result = try await runMacus(arguments)
    #expect(result.status == 0)
    #expect(result.stderr.isEmpty)
    for text in [
      "serve", "capabilities", "TIM_STATE_DIR",
      "runtime status", "runtime start", "runtime stop", "--force", "client setup",
      "--remote", "--set-default", "--incus", "doctor", "--state-dir", "--json",
      "--timeout", "MACUS_STATE_DIR", "650", "10", "macus", "Homebrew",
    ] {
      #expect(result.stdout.contains(text))
    }
    #expect(!result.stdout.contains("show NAME"))
    #expect(!result.stdout.contains("--type"))
  }
  let server = try ScriptedSocket(name: "runtime.sock") { _, _, _ in Data() }
  defer { server.stop() }
  let rejected = [
    ["runtime", "status", "--force"],
    ["list"],
    ["show", "web"],
    ["--timeout", "0", "runtime", "status"],
    ["--timeout", "3601", "doctor"],
    ["--state-dir", "relative", "doctor"],
    ["client", "setup", "--force"],
    ["runtime", "status", "--remote", "macus"],
    ["--incus", "relative", "client", "setup"],
    ["client", "setup", "--remote", "../x"],
    ["runtime"],
    ["--json"],
    ["--json", "--json", "doctor"],
  ]
  for arguments in rejected {
    let result = try await runMacus(arguments + ["--state-dir", server.socket.directory.path])
    #expect(result.status == 2)
    #expect(result.stdout.isEmpty)
  }
  try await Task.sleep(for: .milliseconds(50))
  #expect(server.requests().isEmpty)
}

@Test func stateDirectoryPrecedenceAndReadOnlyNoncreation() async throws {
  let flag = try MacusCLI.stateDirectory(
    flag: "/tmp/flag", environment: ["MACUS_STATE_DIR": "/tmp/env"])
  let env = try MacusCLI.stateDirectory(flag: nil, environment: ["MACUS_STATE_DIR": "/tmp/env"])
  let fallback = try MacusCLI.stateDirectory(flag: nil, environment: [:])
  #expect(flag.path == "/tmp/flag")
  #expect(env.path == "/tmp/env")
  #expect(fallback.path.hasSuffix("/.tama/incus-mac"))
  #expect(throws: RuntimeError.self) {
    try MacusCLI.stateDirectory(flag: nil, environment: ["MACUS_STATE_DIR": "relative"])
  }
  let legacy = ["TIM_STATE_DIR": "/tmp/legacy"]
  let both = ["TIM_STATE_DIR": "/tmp/legacy", "MACUS_STATE_DIR": "/tmp/macus"]
  #expect(try MacusCLI.stateDirectory(flag: nil, environment: legacy).path == "/tmp/legacy")
  #expect(
    try Daemon.stateDirectory(arguments: ["serve"], environment: legacy).path == "/tmp/legacy")
  #expect(try Daemon.stateDirectory(arguments: ["serve"], environment: both).path == "/tmp/macus")
  #expect(try MacusCLI.stateDirectory(flag: nil, environment: both).path == "/tmp/macus")
  #expect(
    try Daemon.stateDirectory(
      arguments: ["serve", "--state-dir", "/tmp/explicit"], environment: both
    ).path == "/tmp/explicit")
  #expect(
    try MacusCLI.stateDirectory(flag: "/tmp/explicit", environment: both).path == "/tmp/explicit")
  #expect(throws: RuntimeError.self) {
    try Daemon.stateDirectory(arguments: ["serve"], environment: ["TIM_STATE_DIR": "relative"])
  }

  let fromEnv = try scriptedRuntime(state: "from-env")
  let fromFlag = try scriptedRuntime(state: "from-flag")
  defer {
    fromEnv.stop()
    fromFlag.stop()
  }
  let envResult = try await runMacus(
    ["--json", "--timeout", "2", "runtime", "status"],
    environment: ["MACUS_STATE_DIR": fromEnv.socket.directory.path])
  let flagResult = try await runMacus(
    [
      "--state-dir", fromFlag.socket.directory.path, "--json", "--timeout", "2", "runtime",
      "status",
    ], environment: ["MACUS_STATE_DIR": fromEnv.socket.directory.path])
  #expect(envResult.status == 0)
  #expect(flagResult.status == 0)
  #expect(try jsonValue(envResult.stdout)["state"] as? String == "from-env")
  #expect(try jsonValue(flagResult.stdout)["state"] as? String == "from-flag")

  let missing = URL(fileURLWithPath: "/tmp/tima\(UUID().uuidString.prefix(8))")
  let absent = try await runMacus([
    "--state-dir", missing.path, "--json", "--timeout", "1", "doctor",
  ])
  #expect(absent.status == 1)
  #expect(absent.stderr.contains("not_found") == false)
  #expect(try jsonValue(absent.stderr)["error"] != nil)
  #expect(!FileManager.default.fileExists(atPath: missing.path))
  let start = try await runMacus([
    "--state-dir", missing.path, "--timeout", "1", "runtime", "start",
  ])
  #expect(start.status == 1)
  #expect(!FileManager.default.fileExists(atPath: missing.path))

  let loose = URL(fileURLWithPath: "/tmp/timl\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
  #expect(chmod(loose.path, 0o755) == 0)
  defer { try? FileManager.default.removeItem(at: loose) }
  let before = try FileManager.default.attributesOfItem(atPath: loose.path)
  let untouched = try await runMacus(["--state-dir", loose.path, "doctor", "--timeout", "1"])
  let after = try FileManager.default.attributesOfItem(atPath: loose.path)
  #expect(untouched.status == 1)
  #expect(before[.posixPermissions] as? NSNumber == after[.posixPermissions] as? NSNumber)
  #expect(try FileManager.default.contentsOfDirectory(atPath: loose.path).isEmpty)
}

@Test func capabilitiesUsesSuppliedOutputStream() async throws {
  let output = OutputCapture()
  let status = await MacusCLI.run(arguments: ["capabilities", "--json"], streams: output.streams)
  #expect(status == 0)
  let captured = output.contents
  #expect(captured.error.isEmpty)
  #expect(captured.output.hasSuffix("\n"))
  let capabilities = try jsonValue(captured.output)
  #expect(capabilities["virtualization"] as? String == "apple-vz")
  #expect(capabilities["platform"] as? String == "darwin")
  #expect(capabilities["supported"] is Bool)
}

@Test func unifiedHostCommandsDoNotCreateState() async throws {
  let missing = URL(fileURLWithPath: "/private/tmp/macus-\(UUID().uuidString.prefix(8))")
  let environment = ["MACUS_STATE_DIR": missing.path]
  let capabilities = try await runMacus(["capabilities"], environment: environment)
  #expect(capabilities.status == 0)
  #expect(capabilities.stdout.contains("apple-vz"))
  for arguments in [
    ["serve", "--state-dir", "relative"],
    ["serve", "--state-dir", missing.path, "--force"],
    ["serve", "--json"], ["capabilities", "--state-dir", missing.path],
  ] {
    let result = try await runMacus(arguments, environment: environment)
    #expect(result.status == 2)
  }
  #expect(!FileManager.default.fileExists(atPath: missing.path))
}

@Test func runtimeJSONExitCodesForceConflictAndTimeout() async throws {
  let server = try ScriptedSocket(name: "runtime.sock") { method, path, _ in
    if method == "POST", path == "/v1/runtime/start" {
      return mustJSON(
        409, errorObject(code: "conflict", message: "A runtime mutation is already in progress"))
    }
    return mustJSON(
      200, statusObject(state: method == "POST" ? "stopped" : "ready", incus: "/tmp/incus.sock"))
  }
  defer { server.stop() }
  let directory = server.socket.directory.path
  let status = try await runMacus([
    "--state-dir", directory, "--json", "--timeout", "2", "runtime", "status",
  ])
  #expect(status.status == 0)
  #expect(status.stderr.isEmpty)
  #expect(try jsonValue(status.stdout)["state"] as? String == "ready")

  let conflict = try await runMacus([
    "--state-dir", directory, "--json", "--timeout", "2", "runtime", "start",
  ])
  #expect(conflict.status == 1)
  #expect(conflict.stdout.isEmpty)
  let conflictError = try jsonValue(conflict.stderr)["error"] as? [String: Any]
  #expect(conflictError?["code"] as? String == "conflict")

  let forced = try await runMacus(
    ["--state-dir", directory, "runtime", "stop", "--force", "--timeout", "2"])
  let plain = try await runMacus(["--state-dir", directory, "--timeout", "2", "runtime", "stop"])
  #expect(forced.status == 0 && plain.status == 0)
  let bodies = server.requests().filter { $0.path == "/v1/runtime/stop" }.map(\.body)
  #expect(bodies.contains(Data("{\"force\":true}".utf8)))
  #expect(bodies.contains(Data("{\"force\":false}".utf8)))

  server.delay = 3
  let started = ContinuousClock.now
  let timedOut = try await runMacus([
    "--state-dir", directory, "--json", "--timeout", "1", "runtime", "status",
  ])
  #expect(timedOut.status == 1)
  #expect(
    try (jsonValue(timedOut.stderr)["error"] as? [String: Any])?["code"] as? String == "timeout")
  #expect(started.duration(to: .now) < .milliseconds(2_500))
}

@Test func doctorDoesNotInstallOrBoot() async throws {
  let stoppedRuntime = try ScriptedSocket(name: "runtime.sock") { _, path, _ in
    if path == "/v1/runtime/status" {
      return mustJSON(200, statusObject(state: "stopped", incus: "/tmp/unused.sock"))
    }
    if path == "/v1/runtime/capabilities" {
      return mustJSON(200, ["supported": true])
    }
    return mustJSON(503, errorObject(code: "unavailable", message: "Incus is not ready"))
  }
  // The first runtime socket was removed with its directory. Use a new state directory.
  defer { stoppedRuntime.stop() }
  let stoppedDir = stoppedRuntime.socket.directory.path
  let doctor = try await runMacus(["--state-dir", stoppedDir, "--json", "--timeout", "2", "doctor"])
  #expect(doctor.status == 1)
  #expect(try jsonValue(doctor.stdout)["status"] != nil)
  #expect(doctor.stdout.contains("stopped"))
  #expect(
    try (jsonValue(doctor.stderr)["error"] as? [String: Any])?["code"] as? String == "unavailable")
  #expect(doctor.stderr.contains("does not start"))
  #expect(stoppedRuntime.requests().allSatisfy { $0.method == "GET" })
  let workload = try await runMacus(["--state-dir", stoppedDir, "list"])
  #expect(workload.status == 2)
  #expect(workload.stderr.contains("standard incus client"))
  #expect(stoppedRuntime.requests().allSatisfy { $0.method == "GET" })
}

@Test func defaultTimeoutsAreAppliedWithoutWaitingForLifecycle() async throws {
  let transport = RecordingTransport()
  let output = OutputCapture()
  let status = await MacusCLI.run(
    arguments: ["runtime", "status"], environment: ["MACUS_STATE_DIR": "/tmp/macus-defaults"],
    transport: transport, streams: output.streams)
  let start = await MacusCLI.run(
    arguments: ["runtime", "start"], environment: ["MACUS_STATE_DIR": "/tmp/macus-defaults"],
    transport: transport, streams: output.streams)
  let override = await MacusCLI.run(
    arguments: ["--timeout", "3", "runtime", "restart"],
    environment: ["MACUS_STATE_DIR": "/tmp/macus-defaults"], transport: transport,
    streams: output.streams)
  let setup = await MacusCLI.run(
    arguments: ["client", "setup"],
    environment: [
      "MACUS_STATE_DIR": "/tmp/macus-defaults", "MACUS_BREW_FALLBACK": "0", "PATH": "/usr/bin:/bin",
    ], transport: transport, streams: output.streams)
  #expect(status == 0 && start == 0 && override == 0 && setup == 1)
  #expect(
    transport.timeouts(for: "/v1/runtime/status") == [
      MacusCLI.readOnlyTimeout, MacusCLI.lifecycleTimeout,
    ])
  #expect(transport.timeouts(for: "/v1/runtime/start") == [MacusCLI.lifecycleTimeout])
  #expect(transport.timeouts(for: "/v1/runtime/restart") == [3])
}

private func scriptedRuntime(state: String) throws -> ScriptedSocket {
  try ScriptedSocket(name: "runtime.sock") { _, _, _ in
    mustJSON(200, statusObject(state: state, incus: "/tmp/incus.sock"))
  }
}

private func jsonValue(_ text: String) throws -> [String: Any] {
  let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
  guard let object = value as? [String: Any] else {
    throw RuntimeError(.io, "Expected JSON object")
  }
  return object
}

private final class RecordingTransport: LocalHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [(String, Int)] = []
  func request(socket: URL, method: String, path: String, body: Data, timeout: Int) async throws
    -> LocalHTTPResponse
  {
    record(path, timeout)
    return LocalHTTPResponse(
      status: 200,
      body: try JSONSerialization.data(
        withJSONObject: statusObject(state: "stopped", incus: "/tmp/incus.sock")))
  }
  func timeouts(for path: String) -> [Int] {
    lock.lock()
    defer { lock.unlock() }
    return calls.filter { $0.0 == path }.map(\.1)
  }
  private func record(_ path: String, _ timeout: Int) {
    lock.lock()
    calls.append((path, timeout))
    lock.unlock()
  }
}

private final class OutputCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var output = ""
  private var error = ""
  var contents: (output: String, error: String) {
    lock.lock()
    defer { lock.unlock() }
    return (output, error)
  }
  var streams: MacusStreams {
    MacusStreams(
      writeOutput: { text in
        self.lock.lock()
        self.output += text
        self.lock.unlock()
      },
      writeError: { text in
        self.lock.lock()
        self.error += text
        self.lock.unlock()
      })
  }
}
