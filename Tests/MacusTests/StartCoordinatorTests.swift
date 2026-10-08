import Darwin
import Foundation
import Testing
import os

@testable import Macus

@Test func concurrentStartsConflictWithoutASecondDownload() async throws {
  let directory = URL(
    fileURLWithPath: "/tmp/macus-cc-\(UUID().uuidString.prefix(8))", isDirectory: true)
  let tools = try StartTools()
  defer {
    tools.remove()
    try? FileManager.default.removeItem(at: directory)
  }
  let gate = GateDownloader()
  let first = Task {
    await MacusCLI.run(
      arguments: ["--state-dir", directory.path, "--incus", tools.incus, "start"],
      environment: tools.environment, streams: StartCapture().streams,
      overrides: tools.overrides(downloader: gate))
  }
  for _ in 0..<100 {
    if gate.calls == 1 { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(gate.calls == 1)
  let second = await MacusCLI.run(
    arguments: ["--state-dir", directory.path, "--incus", tools.incus, "start"],
    environment: tools.environment, streams: StartCapture().streams,
    overrides: tools.overrides(downloader: gate))
  gate.release()
  _ = await first.value
  #expect(second == 1)
  #expect(gate.calls == 1)
}

@Test func partialRuntimeAndTamperedCacheArePreserved() async throws {
  let directory = URL(
    fileURLWithPath: "/tmp/macus-part-\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
  try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
  let sentinel = runtime.appendingPathComponent("data.raw")
  try Data("keep-disk".utf8).write(to: sentinel)
  let downloader = RecordingDownloader()
  let tools = try StartTools()
  defer { tools.remove() }
  let capture = StartCapture()
  let status = await MacusCLI.run(
    arguments: ["--state-dir", directory.path, "--incus", tools.incus, "start"],
    environment: tools.environment, streams: capture.streams,
    overrides: tools.overrides(downloader: downloader))
  #expect(status == 1)
  #expect(downloader.calls == 0)
  #expect(try Data(contentsOf: sentinel) == Data("keep-disk".utf8))
  #expect(capture.error.contains("preserve") || capture.error.contains("Preserve"))
}

@Test func legacyAndForegroundServicesAreNotReplaced() async throws {
  let tools = try StartTools()
  defer { tools.remove() }
  let directory = tools.root.appendingPathComponent("state", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  try Data("config-sentinel".utf8).write(to: directory.appendingPathComponent("config.json"))
  let agents = tools.root.appendingPathComponent("LaunchAgents", isDirectory: true)
  try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
  let legacy = agents.appendingPathComponent("com.kritama.macus.plist")
  let plist: [String: Any] = [
    "Label": "com.kritama.macus",
    "ProgramArguments": ["/old/macus", "serve", "--state-dir", directory.path],
  ]
  let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  try data.write(to: legacy)
  let launch = FakeLaunchControl()
  let capture = StartCapture()
  let conflict = await MacusCLI.run(
    arguments: ["--state-dir", directory.path, "--json", "--incus", tools.incus, "start"],
    environment: tools.environment, streams: capture.streams,
    overrides: tools.overrides(
      downloader: RecordingDownloader(), launchControl: launch, agents: agents))
  #expect(conflict == 1)
  #expect(launch.bootstrapped.isEmpty)
  #expect(try Data(contentsOf: legacy) == data)
  #expect(capture.error.contains("com.kritama.macus"))

  try FileManager.default.removeItem(at: legacy)
  let server = try ScriptedSocket(name: "runtime.sock") { method, path, _ in
    if path == "/v1/runtime/progress" {
      return mustJSON(200, ["api_version": 1, "ready": false, "state": "stopped"])
    }
    return mustJSON(
      200,
      statusObject(state: "stopped", incus: directory.appendingPathComponent("incus.sock").path))
  }
  defer { server.stop() }
  // Move is unnecessary: use the server directory as state and copy the sentinel check via a new dir.
  _ = server
  let foregroundDir = server.socket.directory
  try Data("kept".utf8).write(to: foregroundDir.appendingPathComponent("config.json"))
  try FileManager.default.createDirectory(
    at: foregroundDir.appendingPathComponent("runtime"), withIntermediateDirectories: true)
  try Data("disk".utf8).write(to: foregroundDir.appendingPathComponent("runtime/root.raw"))
  try Data("disk".utf8).write(to: foregroundDir.appendingPathComponent("runtime/data.raw"))
  let again = StartCapture()
  let reused = await MacusCLI.run(
    arguments: [
      "--state-dir", foregroundDir.path, "--json", "--incus", tools.incus, "--progress", "none",
      "start",
    ],
    environment: tools.environment, streams: again.streams,
    overrides: tools.overrides(
      downloader: RecordingDownloader(), launchControl: launch, agents: agents))
  #expect(launch.bootstrapped.isEmpty)
  #expect(reused == 1 || again.output.contains("foreground") || again.error.contains("foreground"))
}

@Test func clientConflictPreservesRemoteAndSkipsDownload() async throws {
  let tools = try StartTools(remotes: ["macus": ["unix:/tmp/elsewhere.sock"]])
  defer { tools.remove() }
  let missing = URL(fileURLWithPath: "/tmp/macus-remote-\(UUID().uuidString.prefix(8))")
  let downloader = RecordingDownloader()
  let capture = StartCapture()
  let status = await MacusCLI.run(
    arguments: ["--state-dir", missing.path, "--json", "--incus", tools.incus, "start"],
    environment: tools.environment, streams: capture.streams,
    overrides: tools.overrides(downloader: downloader))
  #expect(status == 1)
  #expect(downloader.calls == 0)
  #expect(!FileManager.default.fileExists(atPath: missing.path))
  #expect(capture.error.contains("conflict") || capture.error.contains("another --remote"))
  #expect(try tools.remoteAddresses()["macus"] == ["unix:/tmp/elsewhere.sock"])
}

@Test func repeatStartDoesNotChangeResourcesOrReboot() async throws {
  let tools = try StartTools()
  defer { tools.remove() }
  let socketPath = LockedPath()
  let capabilitiesResponse = mustJSON(
    200,
    try JSONSerialization.jsonObject(
      with: JSON.encoder().encode(
        RuntimeCapabilities(
          host: HostCapabilities(supported: true, nestedVirtualization: false),
          health: GuestHealth(incusVersion: "test", apiExtensions: ["instance_oci"], kvm: false),
          nestingEnabled: false))))
  let server = try ScriptedSocket(name: "runtime.sock") { method, path, _ in
    if method == "POST" {
      return mustJSON(500, ["error": ["code": "io", "message": "unexpected mutation"]])
    }
    if path == "/v1/runtime/progress" {
      return mustJSON(200, ["api_version": 1, "ready": true, "state": "ready", "phase": "ready"])
    }
    if path == "/v1/runtime/health" {
      return mustJSON(
        200,
        [
          "protocol_version": 1, "incus_version": "test", "api_extensions": ["instance_oci"],
          "kvm": false,
        ])
    }
    if path == "/v1/runtime/capabilities" { return capabilitiesResponse }
    return mustJSON(200, statusObject(state: "ready", incus: socketPath.value))
  }
  socketPath.value = server.socket.url.path
  defer { server.stop() }
  let directory = server.socket.directory
  let config = directory.appendingPathComponent("config.json")
  try Data("{\"appliance_manifest_path\":\"/tmp/manifest.json\"}".utf8).write(to: config)
  try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("runtime"), withIntermediateDirectories: true)
  try Data("root-sentinel".utf8).write(to: directory.appendingPathComponent("runtime/root.raw"))
  try Data("data-sentinel".utf8).write(to: directory.appendingPathComponent("runtime/data.raw"))
  let before = try Data(contentsOf: config)
  let downloader = RecordingDownloader()
  let launch = FakeLaunchControl()
  let capture = StartCapture()
  let incus = directory.appendingPathComponent("incus.sock").path
  let status = await MacusCLI.run(
    arguments: [
      "--state-dir", directory.path, "--json", "--progress", "none", "--incus", tools.incus,
      "start",
    ],
    environment: tools.environment, streams: capture.streams,
    overrides: tools.overrides(downloader: downloader, launchControl: launch))
  #expect(status == 0)
  #expect(capture.error.contains("\u{1B}") == false)
  let object = try JSONSerialization.jsonObject(with: Data(capture.output.utf8)) as? [String: Any]
  #expect(object?["ready"] as? Bool == true)
  #expect(object?["remote"] as? String == "macus")
  #expect(object?["incus"] as? String == tools.incus)
  #expect(object?["service_ownership"] as? String == "foreground")
  #expect((object?["next_commands"] as? [String])?.first?.contains("incus list macus:") == true)
  #expect(downloader.calls == 0)
  #expect(launch.bootstrapped.isEmpty)
  #expect(try Data(contentsOf: config) == before)
  #expect(
    try Data(contentsOf: directory.appendingPathComponent("runtime/data.raw"))
      == Data("data-sentinel".utf8))
  #expect(server.requests().contains { $0.method == "POST" } == false)
  _ = incus
}

@Test func macusStartClientStageDoesNotResetTheDeadline() async throws {
  let tools = try StartTools()
  defer { tools.remove() }
  let socketPath = LockedPath()
  let capabilities = mustJSON(
    200,
    try JSONSerialization.jsonObject(
      with: JSON.encoder().encode(
        RuntimeCapabilities(
          host: HostCapabilities(supported: true, nestedVirtualization: false),
          health: GuestHealth(incusVersion: "test", apiExtensions: [], kvm: false),
          nestingEnabled: false))))
  let server = try ScriptedSocket(name: "runtime.sock") { method, path, _ in
    if method == "POST" {
      return mustJSON(500, ["error": ["code": "io", "message": "unexpected mutation"]])
    }
    if path == "/v1/runtime/progress" {
      return mustJSON(200, ["api_version": 1, "ready": true, "state": "ready"])
    }
    if path == "/v1/runtime/health" {
      return mustJSON(
        200, ["protocol_version": 1, "incus_version": "test", "api_extensions": [], "kvm": false]
      )
    }
    if path == "/v1/runtime/capabilities" { return capabilities }
    return mustJSON(200, statusObject(state: "ready", incus: socketPath.value))
  }
  socketPath.value = server.socket.url.path
  defer { server.stop() }
  let directory = server.socket.directory
  try Data("{\"appliance_manifest_path\":\"/tmp/manifest.json\"}".utf8).write(
    to: directory.appendingPathComponent("config.json"))
  try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("runtime"), withIntermediateDirectories: true)
  try Data("disk".utf8).write(to: directory.appendingPathComponent("runtime/root.raw"))
  try Data("disk".utf8).write(to: directory.appendingPathComponent("runtime/data.raw"))
  let runner = BudgetRunner(delayMilliseconds: 700, mode: .incus)
  var overrides = tools.overrides(downloader: RecordingDownloader())
  overrides.runner = runner
  let started = ContinuousClock.now
  let capture = StartCapture()
  let status = await MacusCLI.run(
    arguments: [
      "--state-dir", directory.path, "--timeout", "2", "--json", "--progress", "none", "--incus",
      tools.incus, "start",
    ],
    environment: tools.environment, streams: capture.streams, overrides: overrides)
  #expect(status == 1)
  #expect(capture.error.contains("timeout"))
  #expect(capture.output.isEmpty)
  #expect(!runner.timeouts.isEmpty)
  #expect(runner.timeouts.count < 4, "timeouts=\(runner.timeouts)")
  #expect(runner.timeouts.allSatisfy { $0 < 5 }, "timeouts=\(runner.timeouts)")
  #expect(started.duration(to: .now) < .seconds(3))
  #expect(server.requests().contains { $0.method == "POST" } == false)
}

@Test func clientStageSharesOneDeadlineAcrossFastSubprocesses() async throws {
  let runner = BudgetRunner(delayMilliseconds: 700, mode: .incus)
  let started = ContinuousClock.now
  let service = IncusClientService(
    runner: runner,
    streams: MacusStreams(writeOutput: { _ in }, writeError: { _ in }),
    environment: ["PATH": "/usr/bin:/bin", "MACUS_BREW_FALLBACK": "0"])
  do {
    _ = try await service.register(
      remote: "macus", setDefault: false, incusOverride: "/usr/bin/true",
      socketPath: "/private/tmp/probe.sock", timeout: 5,
      deadline: started.advanced(by: .seconds(2)))
    Issue.record("client registration reset the start deadline")
  } catch let error as RuntimeError {
    #expect(error.code == .timeout)
  }
  #expect(!runner.timeouts.isEmpty)
  #expect(runner.timeouts.count < 4, "timeouts=\(runner.timeouts)")
  #expect(runner.timeouts.allSatisfy { $0 < 5 }, "timeouts=\(runner.timeouts)")
  #expect(started.duration(to: .now) < .seconds(3))

  let preserved = BudgetRunner(delayMilliseconds: 40, mode: .incus)
  let setup = try await serviceWith(preserved).register(
    remote: "macus", setDefault: false, incusOverride: "/usr/bin/true",
    socketPath: "/private/tmp/probe.sock", timeout: 5, deadline: nil)
  #expect(setup.connected)
  #expect(preserved.timeouts.count >= 3)
  #expect(preserved.timeouts.allSatisfy { $0 == 5 })
}

@Test func homebrewDiscoverySharesTheStartDeadline() async throws {
  let root = URL(fileURLWithPath: "/tmp/macus-brew-\(UUID().uuidString.prefix(8))")
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let brew = bin.appendingPathComponent("brew")
  try Data("#!/bin/sh\nexit 0\n".utf8).write(to: brew)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
  let runner = BudgetRunner(delayMilliseconds: 700, mode: .brew)
  let service = IncusClientService(
    runner: runner,
    streams: MacusStreams(writeOutput: { _ in }, writeError: { _ in }),
    environment: ["PATH": bin.path, "MACUS_BREW_FALLBACK": "0"])
  let started = ContinuousClock.now
  do {
    _ = try await service.resolve(
      override: nil, timeout: 5, deadline: started.advanced(by: .seconds(2)))
    Issue.record("Homebrew discovery reset the start deadline")
  } catch let error as RuntimeError {
    #expect(error.code == .timeout)
  }
  #expect(!runner.timeouts.isEmpty)
  #expect(runner.timeouts.count < 3, "timeouts=\(runner.timeouts)")
  #expect(runner.timeouts.allSatisfy { $0 < 5 }, "timeouts=\(runner.timeouts)")
  #expect(started.duration(to: .now) < .seconds(3))
}

@Test func sameLabelServicePlistIsNotReplaced() async throws {
  let root = URL(
    fileURLWithPath: "/tmp/macus-plist-\(UUID().uuidString.prefix(8))", isDirectory: true)
  let home = root.appendingPathComponent("home", isDirectory: true)
  let state = home.appendingPathComponent(".tama/incus-mac", isDirectory: true)
  let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
  try FileManager.default.createDirectory(
    at: state.appendingPathComponent("runtime"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try Data("root-sentinel".utf8).write(to: state.appendingPathComponent("runtime/root.raw"))
  try Data("data-sentinel".utf8).write(to: state.appendingPathComponent("runtime/data.raw"))
  try Data("{\"appliance_manifest_path\":\"/tmp/manifest.json\"}".utf8).write(
    to: state.appendingPathComponent("config.json"))
  let plist = agents.appendingPathComponent("com.upmaru.macus.plist")
  let other = root.appendingPathComponent("other-state").path
  let conflicting = try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": "com.upmaru.macus",
      "ProgramArguments": ["/usr/bin/true", "serve", "--state-dir", other],
    ], format: .xml, options: 0)
  try conflicting.write(to: plist)
  let launch = RecordingLaunch()
  do {
    _ = try await StartupCoordinator(
      dependencies: plistDependencies(
        home: home, state: state, agents: agents, launch: launch, timeout: 2
      )
    ).run(plistRequest(state))
  } catch {}
  #expect(try Data(contentsOf: plist) == conflicting)
  #expect(launch.bootstrapped.isEmpty)
  #expect(
    try Data(contentsOf: state.appendingPathComponent("runtime/data.raw"))
      == Data("data-sentinel".utf8))

  let differentExecutable = try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": "com.upmaru.macus",
      "ProgramArguments": ["/usr/bin/false", "serve", "--state-dir", state.path],
    ], format: .xml, options: 0)
  try differentExecutable.write(to: plist)
  launch.bootstrapped.removeAll()
  do {
    _ = try await StartupCoordinator(
      dependencies: plistDependencies(
        home: home, state: state, agents: agents, launch: launch, timeout: 2
      )
    ).run(plistRequest(state))
  } catch {}
  #expect(try Data(contentsOf: plist) == differentExecutable)
  #expect(launch.bootstrapped.isEmpty)

  let matching = try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": "com.upmaru.macus",
      "ProgramArguments": LaunchAgentPlan.arguments(
        executable: "/usr/bin/true", stateDirectory: state),
    ], format: .xml, options: 0)
  try matching.write(to: plist)
  #expect(throws: RuntimeError.self) {
    try LaunchAgentPlan.write(
      stateDirectory: state, home: home, launchAgents: agents, executable: "/other/macus")
  }
  #expect(try Data(contentsOf: plist) == matching)
}

private func serviceWith(_ runner: BudgetRunner) -> IncusClientService {
  IncusClientService(
    runner: runner,
    streams: MacusStreams(writeOutput: { _ in }, writeError: { _ in }),
    environment: ["PATH": "/usr/bin:/bin", "MACUS_BREW_FALLBACK": "0"])
}

private func plistRequest(_ state: URL) -> StartupRequest {
  StartupRequest(
    stateDirectory: state, remote: "macus", setDefault: false, incusOverride: "/usr/bin/true",
    timeout: 2, environment: ["PATH": "/usr/bin:/bin", "MACUS_BREW_FALLBACK": "0"])
}

private func plistDependencies(
  home: URL, state: URL, agents: URL, launch: RecordingLaunch, timeout: Int
) -> StartupDependencies {
  StartupDependencies(
    transport: UnusedProbeTransport(),
    runner: BudgetRunner(delayMilliseconds: 1, mode: .incus),
    downloader: UnusedProbeDownloader(),
    launchControl: launch,
    capabilities: { HostCapabilities(supported: true, nestedVirtualization: false) },
    hasEntitlement: { true },
    executablePath: { "/usr/bin/true" },
    now: { .now },
    homeDirectory: home,
    launchAgentsDirectory: agents,
    uid: getuid(),
    catalog: .current,
    sink: CollectingProgressSink())
}

private final class LockedPath: @unchecked Sendable {
  var value = ""
}

private struct StartTools {
  let root: URL
  let incus: String
  let environment: [String: String]
  init(remotes: [String: [String]] = [:]) throws {
    root = URL(
      fileURLWithPath: "/tmp/macus-tools-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    incus = root.appendingPathComponent("incus").path
    let state = root.appendingPathComponent("incus.json")
    let initial: [String: Any] = ["default": "local", "remotes": remotes]
    try JSONSerialization.data(withJSONObject: initial).write(to: state)
    let script = """
      #!/usr/bin/python3
      import json, os, sys
      path = os.environ["MACUS_FIXTURE_STATE"]
      state = json.load(open(path))
      args = sys.argv[1:]
      if args[:4] == ["remote", "list", "--format", "json"]:
          print(json.dumps({name: {"Addrs": addrs} for name, addrs in state["remotes"].items()}))
      elif args == ["remote", "get-default"]:
          print(state["default"])
      elif len(args) == 4 and args[:2] == ["remote", "add"]:
          state["remotes"][args[2]] = [args[3]]
      elif len(args) == 3 and args[:2] == ["remote", "switch"]:
          state["default"] = args[2]
      elif len(args) == 2 and args[0] == "list":
          name = args[1][:-1]
          if name not in state["remotes"]:
              sys.exit(1)
      else:
          sys.exit(2)
      json.dump(state, open(path, "w"))
      """
    try script.write(to: URL(fileURLWithPath: incus), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: incus)
    environment = [
      "PATH": "/usr/bin:/bin", "MACUS_BREW_FALLBACK": "0", "MACUS_FIXTURE_STATE": state.path,
      "INCUS_CONF": root.appendingPathComponent("conf").path,
    ]
  }
  func overrides(
    downloader: any ApplianceDownloader, launchControl: (any LaunchControl)? = nil,
    agents: URL? = nil
  ) -> StartupOverrides {
    StartupOverrides(
      capabilities: { HostCapabilities(supported: true, nestedVirtualization: false) },
      hasEntitlement: { true },
      downloader: downloader,
      launchControl: launchControl ?? FakeLaunchControl(),
      executablePath: { "/usr/bin/true" },
      homeDirectory: root,
      launchAgentsDirectory: agents ?? root.appendingPathComponent("LaunchAgents"),
      installSignals: false)
  }
  func remoteAddresses() throws -> [String: [String]] {
    let object =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("incus.json"))) as? [String: Any]
    return object?["remotes"] as? [String: [String]] ?? [:]
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class GateDownloader: ApplianceDownloader, @unchecked Sendable {
  private let counter = OSAllocatedUnfairLock(initialState: 0)
  private let gate = WaitGate()
  var calls: Int { counter.withLock { $0 } }
  func download(
    url: URL, to destination: URL, maximumBytes: Int64, deadline: ContinuousClock.Instant,
    onBytes: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws {
    counter.withLock { $0 += 1 }
    await gate.wait()
  }
  func release() { Task { await gate.release() } }
}

private final class BudgetRunner: LocalCommandRunner, @unchecked Sendable {
  enum Mode { case incus, brew }
  var delayMilliseconds: Int
  var mode: Mode
  private let recorded = OSAllocatedUnfairLock(initialState: [Int]())
  init(delayMilliseconds: Int, mode: Mode) {
    self.delayMilliseconds = delayMilliseconds
    self.mode = mode
  }
  var timeouts: [Int] { recorded.withLock { $0 } }
  func run(
    executable: String, arguments: [String], environment: [String: String], timeout: Int
  ) async throws -> LocalCommandResult {
    recorded.withLock { $0.append(timeout) }
    try await Task.sleep(for: .milliseconds(delayMilliseconds))
    let text: String
    if mode == .brew {
      text = ""
    } else if arguments == ["remote", "get-default"] {
      text = "local\n"
    } else if arguments == ["remote", "list", "--format", "json"] {
      text = "{}\n"
    } else {
      text = ""
    }
    return LocalCommandResult(status: 0, stdout: Data(text.utf8), stderr: Data())
  }
}

@Test func loadedMatchingJobIsReusedWithoutBootstrap() async throws {
  let tools = try StartTools()
  defer { tools.remove() }
  let directory = URL(fileURLWithPath: "/tmp/macus-job-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("runtime"), withIntermediateDirectories: true)
  try Data("root".utf8).write(to: directory.appendingPathComponent("runtime/root.raw"))
  try Data("data".utf8).write(to: directory.appendingPathComponent("runtime/data.raw"))
  try Data("{\"appliance_manifest_path\":\"/tmp/manifest.json\"}".utf8).write(
    to: directory.appendingPathComponent("config.json"))
  let executable = "/usr/bin/true"
  let label = LaunchAgentPlan.label(stateDirectory: directory, home: tools.root)
  let plist = try LaunchAgentPlan.write(
    stateDirectory: directory, home: tools.root,
    launchAgents: tools.root.appendingPathComponent("LaunchAgents"), executable: executable)
  let before = try Data(contentsOf: plist)
  let launch = FakeLaunchControl()
  launch.jobs[label] = LaunchJob(
    label: label, loaded: true,
    programArguments: LaunchAgentPlan.arguments(
      executable: executable, stateDirectory: directory))
  let capture = StartCapture()
  let task = Task {
    await MacusCLI.run(
      arguments: [
        "--state-dir", directory.path, "--json", "--progress", "none", "--timeout", "5",
        "--incus", tools.incus, "start",
      ],
      environment: tools.environment, streams: capture.streams,
      overrides: tools.overrides(downloader: RecordingDownloader(), launchControl: launch))
  }
  try await Task.sleep(for: .milliseconds(200))
  #expect(launch.bootstrapped.isEmpty)
  let server = try ScriptedSocket(name: "runtime.sock", directory: directory) { method, path, _ in
    readyRuntime(method: method, path: path, directory: directory)
  }
  defer { server.stop() }
  #expect(await task.value == 0)
  #expect(launch.bootstrapped.isEmpty)
  #expect(try Data(contentsOf: plist) == before)
  #expect(capture.output.contains("launchd"))
}

@Test func loadedConflictingJobIsNotActivated() async throws {
  let tools = try StartTools()
  defer { tools.remove() }
  let directory = URL(fileURLWithPath: "/tmp/macus-badjob-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("runtime"), withIntermediateDirectories: true)
  try Data("root".utf8).write(to: directory.appendingPathComponent("runtime/root.raw"))
  try Data("data".utf8).write(to: directory.appendingPathComponent("runtime/data.raw"))
  try Data("{\"appliance_manifest_path\":\"/tmp/manifest.json\"}".utf8).write(
    to: directory.appendingPathComponent("config.json"))
  let label = LaunchAgentPlan.label(stateDirectory: directory, home: tools.root)
  let plist = try LaunchAgentPlan.write(
    stateDirectory: directory, home: tools.root,
    launchAgents: tools.root.appendingPathComponent("LaunchAgents"), executable: "/usr/bin/true")
  let before = try Data(contentsOf: plist)
  let launch = FakeLaunchControl()
  launch.jobs[label] = LaunchJob(
    label: label, loaded: true,
    programArguments: ["/other/macus", "serve", "--state-dir", directory.path])
  let capture = StartCapture()
  let status = await MacusCLI.run(
    arguments: [
      "--state-dir", directory.path, "--json", "--timeout", "2", "--incus", tools.incus, "start",
    ],
    environment: tools.environment, streams: capture.streams,
    overrides: tools.overrides(downloader: RecordingDownloader(), launchControl: launch))
  #expect(status == 1)
  #expect(launch.bootstrapped.isEmpty)
  #expect(try Data(contentsOf: plist) == before)
  #expect(capture.error.contains("will not replace"))
}

@Test func neverReadyLoadedJobTimesOutWithoutBootstrap() async throws {
  let tools = try StartTools()
  defer { tools.remove() }
  let directory = URL(fileURLWithPath: "/tmp/macus-wait-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("runtime"), withIntermediateDirectories: true)
  try Data("root".utf8).write(to: directory.appendingPathComponent("runtime/root.raw"))
  try Data("data".utf8).write(to: directory.appendingPathComponent("runtime/data.raw"))
  try Data("{\"appliance_manifest_path\":\"/tmp/manifest.json\"}".utf8).write(
    to: directory.appendingPathComponent("config.json"))
  let label = LaunchAgentPlan.label(stateDirectory: directory, home: tools.root)
  let plist = try LaunchAgentPlan.write(
    stateDirectory: directory, home: tools.root,
    launchAgents: tools.root.appendingPathComponent("LaunchAgents"), executable: "/usr/bin/true")
  let before = try Data(contentsOf: plist)
  let launch = FakeLaunchControl()
  launch.jobs[label] = LaunchJob(
    label: label, loaded: true,
    programArguments: LaunchAgentPlan.arguments(
      executable: "/usr/bin/true", stateDirectory: directory))
  let capture = StartCapture()
  let started = ContinuousClock.now
  let status = await MacusCLI.run(
    arguments: [
      "--state-dir", directory.path, "--json", "--timeout", "2", "--incus", tools.incus, "start",
    ],
    environment: tools.environment, streams: capture.streams,
    overrides: tools.overrides(downloader: RecordingDownloader(), launchControl: launch))
  #expect(status == 1)
  #expect(launch.bootstrapped.isEmpty)
  #expect(try Data(contentsOf: plist) == before)
  #expect(capture.error.contains("control endpoint"))
  #expect(started.duration(to: .now) > .milliseconds(500))
  #expect(started.duration(to: .now) < .seconds(3))
}

@Test func absentJobIsBootstrappedOnce() async throws {
  let tools = try StartTools()
  defer { tools.remove() }
  let directory = URL(fileURLWithPath: "/tmp/macus-newjob-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("runtime"), withIntermediateDirectories: true)
  try Data("root".utf8).write(to: directory.appendingPathComponent("runtime/root.raw"))
  try Data("data".utf8).write(to: directory.appendingPathComponent("runtime/data.raw"))
  try Data("{\"appliance_manifest_path\":\"/tmp/manifest.json\"}".utf8).write(
    to: directory.appendingPathComponent("config.json"))
  let launch = SocketOnBootstrap(directory: directory)
  let status = await MacusCLI.run(
    arguments: [
      "--state-dir", directory.path, "--json", "--progress", "none", "--timeout", "5",
      "--incus", tools.incus, "start",
    ],
    environment: tools.environment, streams: StartCapture().streams,
    overrides: tools.overrides(downloader: RecordingDownloader(), launchControl: launch))
  #expect(status == 0)
  #expect(launch.bootstrapped.count == 1)
  launch.server?.stop()
}

private func readyRuntime(method: String, path: String, directory: URL) -> Data {
  if method == "POST" {
    return mustJSON(500, ["error": ["code": "io", "message": "unexpected mutation"]])
  }
  if path == "/v1/runtime/progress" {
    return mustJSON(200, ["api_version": 1, "ready": true, "state": "ready", "phase": "ready"])
  }
  if path == "/v1/runtime/health" {
    return mustJSON(
      200, ["protocol_version": 1, "incus_version": "test", "api_extensions": [], "kvm": false])
  }
  if path == "/v1/runtime/capabilities" {
    let encoded = try? JSON.encoder().encode(
      RuntimeCapabilities(
        host: HostCapabilities(supported: true, nestedVirtualization: false),
        health: GuestHealth(incusVersion: "test", apiExtensions: [], kvm: false),
        nestingEnabled: false))
    return mustJSON(200, (try? JSONSerialization.jsonObject(with: encoded ?? Data())) ?? [:])
  }
  return mustJSON(
    200, statusObject(state: "ready", incus: directory.appendingPathComponent("incus.sock").path))
}

private final class SocketOnBootstrap: LaunchControl, @unchecked Sendable {
  let directory: URL
  var bootstrapped: [String] = []
  var server: ScriptedSocket?
  init(directory: URL) { self.directory = directory }
  func printJob(label: String, timeout: Int) async throws -> LaunchJob? { nil }
  func bootstrap(plist: URL, timeout: Int) async throws {
    bootstrapped.append(plist.path)
    let state = self.directory
    server = try ScriptedSocket(name: "runtime.sock", directory: state) { method, path, _ in
      readyRuntime(method: method, path: path, directory: state)
    }
  }
  func plist(at url: URL) throws -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
      as? [String: Any]
  }
}

private struct UnusedProbeTransport: LocalHTTPTransport {
  func request(socket: URL, method: String, path: String, body: Data, timeout: Int) async throws
    -> LocalHTTPResponse
  {
    throw RuntimeError(.unavailable, "No endpoint in plist regression")
  }
}

private struct UnusedProbeDownloader: ApplianceDownloader {
  func download(
    url: URL, to destination: URL, maximumBytes: Int64, deadline: ContinuousClock.Instant,
    onBytes: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws {
    throw RuntimeError(.io, "Download must not run in plist regression")
  }
}

private final class RecordingLaunch: LaunchControl, @unchecked Sendable {
  var bootstrapped: [String] = []
  func printJob(label: String, timeout: Int) async throws -> LaunchJob? { nil }
  func bootstrap(plist: URL, timeout: Int) async throws { bootstrapped.append(plist.path) }
  func plist(at url: URL) throws -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
      as? [String: Any]
  }
}

private actor WaitGate {
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation { self.continuation = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
