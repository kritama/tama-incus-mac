import Darwin
import Foundation
import Testing

@testable import TamaIncusMac

@Test func clientSetupInstallsDiscoversAndPreservesConfiguration() async throws {
  let runtime = try readyRuntime()
  defer { runtime.socket.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeBrew(mode: .install)
  try tools.writeIncus(
    defaultRemote: "other",
    remotes: [
      "local": ["unix://"], "other": ["unix:/tmp/other.sock"],
    ])
  let first = try runTim(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: tools.environment())
  #expect(first.status == 0)
  #expect(first.stderr.contains("installing official Homebrew formula incus"))
  let body = try jsonObject(first.stdout)
  #expect(body["remote"] as? String == "tama-mac")
  #expect(body["installed"] as? Bool == true)
  #expect(body["connected"] as? Bool == true)
  #expect(body["default"] as? Bool == false)
  #expect((body["incus"] as? String)?.hasSuffix("/prefix/bin/incus") == true)
  #expect(body["address"] as? String == "unix:\(runtime.incusPath)")
  let saved = try tools.readState()
  #expect(saved.defaultRemote == "other")
  #expect(saved.remotes["other"] == ["unix:/tmp/other.sock"])
  #expect(try tools.commands().filter { $0.first == "install" }.count == 1)

  let again = try runTim(
    [
      "--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup",
      "--set-default",
    ],
    environment: tools.environment())
  #expect(again.status == 0)
  #expect(try jsonObject(again.stdout)["default"] as? Bool == true)
  #expect(try tools.commands().filter { $0.first == "install" }.count == 1)
  #expect(
    try tools.incusArguments().filter {
      $0 == ["remote", "add", "tama-mac", "unix:\(runtime.incusPath)"]
    }.count == 1)
  let switched = try tools.readState()
  #expect(switched.defaultRemote == "tama-mac")
  #expect(switched.remotes["other"] == ["unix:/tmp/other.sock"])
}

@Test func clientSetupConflictsAndSkipsInstallWhenRuntimeIsNotReady() async throws {
  let runtime = try readyRuntime()
  defer { runtime.socket.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeBrew(mode: .install)
  try tools.writeIncus(
    defaultRemote: "local",
    remotes: [
      "local": ["unix://"], "tama-mac": ["unix:/tmp/elsewhere.sock"],
    ])
  try tools.publishOnPath()
  let conflict = try runTim(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: tools.environment())
  #expect(conflict.status == 1)
  #expect(conflict.stdout.isEmpty)
  #expect(
    try (jsonObject(conflict.stderr)["error"] as? [String: Any])?["code"] as? String == "conflict")
  #expect(try tools.readState().remotes["tama-mac"] == ["unix:/tmp/elsewhere.sock"])
  #expect(try tools.commands().filter { $0.first == "install" }.isEmpty)
  let added = try tools.incusArguments().contains { $0.prefix(2) == ["remote", "add"] }
  #expect(!added)

  let stoppedTools = try ToolFixture()
  defer { stoppedTools.remove() }
  try stoppedTools.writeBrew(mode: .install)
  let stopped = try ScriptedSocket(name: "runtime.sock") { _, _, _ in
    mustJSON(200, statusObject(state: "stopped", incus: "/tmp/unused.sock"))
  }
  defer { stopped.stop() }
  let blocked = try runTim(
    ["--state-dir", stopped.socket.directory.path, "--timeout", "5", "client", "setup"],
    environment: stoppedTools.environment())
  #expect(blocked.status == 1)
  #expect(blocked.stderr.contains("not ready"))
  #expect(stoppedTools.logText().isEmpty)
}

@Test func missingHomebrewIsGuidanceAndBrewFailureDoesNotRegister() async throws {
  let runtime = try readyRuntime()
  defer { runtime.socket.stop() }
  let missing = try ToolFixture()
  defer { missing.remove() }
  let absent = try runTim(
    ["--state-dir", runtime.directory, "--timeout", "5", "client", "setup"],
    environment: missing.environment(includeBrew: false))
  #expect(absent.status == 1)
  #expect(absent.stderr.contains("https://brew.sh"))
  #expect(absent.stderr.contains("does not install Homebrew"))

  let failing = try ToolFixture()
  defer { failing.remove() }
  try failing.writeBrew(mode: .fail)
  try failing.writeIncus(defaultRemote: "local", remotes: ["local": ["unix://"]])
  let failed = try runTim(
    ["--state-dir", runtime.directory, "--timeout", "5", "client", "setup"],
    environment: failing.environment())
  #expect(failed.status == 1)
  #expect(failed.stderr.contains("Homebrew install of incus failed"))
  #expect(try failing.incusArguments().isEmpty)
}

@Test func brewInstallTimeoutReapsTheChild() async throws {
  let runtime = try readyRuntime()
  defer { runtime.socket.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeBrew(mode: .sleep)
  let started = ContinuousClock.now
  let result = try runTim(
    ["--state-dir", runtime.directory, "--json", "--timeout", "1", "client", "setup"],
    environment: tools.environment())
  #expect(result.status == 1)
  #expect(result.stderr.contains("\"timeout\""))
  #expect(started.duration(to: .now) < .milliseconds(2_500))
  let pidLine = try #require(
    tools.logText().split(separator: "\n").first { $0.hasPrefix("brew-pid:") })
  let pid = try #require(pid_t(pidLine.dropFirst("brew-pid:".count)))
  #expect(kill(pid, 0) == -1)
  #expect(errno == ESRCH)
}

@Test func explicitIncusOverrideSkipsPathAndHomebrew() async throws {
  let runtime = try readyRuntime()
  defer { runtime.socket.stop() }
  let decoy = try ToolFixture()
  defer { decoy.remove() }
  try decoy.writeBrew(mode: .fail)
  let selected = try ToolFixture()
  defer { selected.remove() }
  try selected.writeIncus(defaultRemote: "local", remotes: ["local": ["unix://"]])
  var environment = selected.environment(includeBrew: false)
  environment["PATH"] = "\(decoy.bin.path):/usr/bin:/bin"
  let result = try runTim(
    [
      "--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup", "--incus",
      selected.incusPath, "--remote", "desk",
    ], environment: environment)
  #expect(result.status == 0)
  #expect(try jsonObject(result.stdout)["remote"] as? String == "desk")
  #expect(try jsonObject(result.stdout)["installed"] as? Bool == false)
  #expect(try decoy.commands().isEmpty)
  #expect(try selected.incusArguments().contains(["list", "desk:"]))
}

@Test func unreadableIncusDefaultFailsBeforeRegistration() async throws {
  let runtime = try readyRuntime()
  defer { runtime.socket.stop() }
  let tools = try ToolFixture()
  defer { tools.remove() }
  try tools.writeIncus(defaultRemote: "other", remotes: ["other": ["unix:/tmp/other.sock"]])
  try tools.publishOnPath()
  var environment = tools.environment(includeBrew: false)
  environment["PATH"] = "\(tools.bin.path):/usr/bin:/bin"
  environment["TIM_FIXTURE_DEFAULT_FAIL"] = "1"
  let result = try runTim(
    ["--state-dir", runtime.directory, "--json", "--timeout", "5", "client", "setup"],
    environment: environment)
  #expect(result.status == 1)
  #expect(result.stderr.contains("Cannot read the existing Incus default"))
  #expect(try tools.incusArguments() == [["remote", "get-default"]])
  #expect(try tools.readState().defaultRemote == "other")
  #expect(try tools.readState().remotes["tama-mac"] == nil)
}

private struct ReadyRuntime {
  var socket: PrivateUNIXSocket
  var incus: PrivateUNIXSocket
  var directory: String { socket.directory.path }
  var incusPath: String { incus.url.path }
}

private func readyRuntime() throws -> ReadyRuntime {
  let incus = try PrivateUNIXSocket(name: "incus.sock")
  let runtime = try ScriptedSocket(name: "runtime.sock") { _, _, _ in
    mustJSON(200, statusObject(state: "ready", incus: incus.url.path))
  }
  return ReadyRuntime(socket: runtime.socket, incus: incus)
}

private enum BrewMode { case install, fail, sleep }

private struct ToolFixture {
  let root: URL
  let bin: URL
  let prefix: URL
  let log: URL
  let state: URL
  let incusPath: String

  init() throws {
    root = URL(fileURLWithPath: "/tmp/tims\(UUID().uuidString.prefix(8))", isDirectory: true)
    bin = root.appendingPathComponent("bin", isDirectory: true)
    prefix = root.appendingPathComponent("prefix", isDirectory: true)
    log = root.appendingPathComponent("commands.log")
    state = root.appendingPathComponent("incus-state.json")
    incusPath = root.appendingPathComponent("incus-template").path
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: Data())
  }

  func environment(includeBrew: Bool = true) -> [String: String] {
    var path = "/usr/bin:/bin"
    if includeBrew {
      path = "\(bin.path):" + path
    }
    return [
      "PATH": path, "TIM_BREW_FALLBACK": "0", "TIM_FIXTURE_LOG": log.path,
      "TIM_FIXTURE_STATE": state.path, "TIM_FIXTURE_PREFIX": prefix.path,
      "TIM_FIXTURE_INCUS": incusPath,
    ]
  }

  func writeBrew(mode: BrewMode) throws {
    let script: String
    switch mode {
    case .install:
      script = """
        #!/bin/sh
        printf '%s\\n' \"$*\" >> \"$TIM_FIXTURE_LOG\"
        if [ \"$1\" = \"--prefix\" ]; then
          printf '%s\\n' \"$TIM_FIXTURE_PREFIX\"
          exit 0
        fi
        if [ \"$1\" = \"install\" ] && [ \"$2\" = \"incus\" ]; then
          mkdir -p \"$TIM_FIXTURE_PREFIX/bin\"
          cp \"$TIM_FIXTURE_INCUS\" \"$TIM_FIXTURE_PREFIX/bin/incus\"
          chmod 755 \"$TIM_FIXTURE_PREFIX/bin/incus\"
          echo installed >&2
          exit 0
        fi
        echo unexpected >&2
        exit 2
        """
    case .fail:
      script = """
        #!/bin/sh
        printf '%s\\n' \"$*\" >> \"$TIM_FIXTURE_LOG\"
        echo formula unavailable >&2
        exit 1
        """
    case .sleep:
      script = """
        #!/usr/bin/python3
        import os, time
        open(os.environ["TIM_FIXTURE_LOG"], "a").write("brew-pid:" + str(os.getpid()) + "\\n")
        time.sleep(5)
        open(os.environ["TIM_FIXTURE_LOG"], "a").write("brew-done\\n")
        """
    }
    try writeExecutable(bin.appendingPathComponent("brew"), script)
  }

  func writeIncus(defaultRemote: String, remotes: [String: [String]]) throws {
    let initial: [String: Any] = ["default": defaultRemote, "remotes": remotes]
    let data = try JSONSerialization.data(withJSONObject: initial)
    try data.write(to: state)
    let script = """
      #!/usr/bin/python3
      import json, os, sys
      log = os.environ["TIM_FIXTURE_LOG"]
      path = os.environ["TIM_FIXTURE_STATE"]
      with open(log, "a") as handle:
          handle.write(json.dumps(sys.argv[1:]) + "\\n")
      with open(path) as handle:
          state = json.load(handle)
      args = sys.argv[1:]
      if args[:3] == ["remote", "list", "--format"] and args[3:] == ["json"]:
          payload = {name: {"Addrs": addrs} for name, addrs in state["remotes"].items()}
          print(json.dumps(payload))
      elif args == ["remote", "get-default"]:
          if os.environ.get("TIM_FIXTURE_DEFAULT_FAIL") == "1":
              sys.exit(1)
          print(state["default"])
      elif len(args) == 4 and args[:2] == ["remote", "add"]:
          name, address = args[2], args[3]
          if name in state["remotes"]:
              print("already exists", file=sys.stderr)
              sys.exit(1)
          state["remotes"][name] = [address]
      elif len(args) == 3 and args[:2] == ["remote", "switch"]:
          state["default"] = args[2]
      elif len(args) == 2 and args[0] == "list" and args[1].endswith(":"):
          name = args[1][:-1]
          if name not in state["remotes"]:
              print("missing remote", file=sys.stderr)
              sys.exit(1)
      else:
          print("unexpected", args, file=sys.stderr)
          sys.exit(2)
      with open(path, "w") as handle:
          json.dump(state, handle)
      """
    try writeExecutable(URL(fileURLWithPath: incusPath), script)
  }

  func publishOnPath() throws {
    let destination = bin.appendingPathComponent("incus")
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: URL(fileURLWithPath: incusPath), to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: destination.path)
  }

  func commands() throws -> [[String]] {
    logText().split(separator: "\n").compactMap { line in
      let text = String(line)
      guard text.hasPrefix("[") || text.hasPrefix("install") || text.hasPrefix("--prefix") else {
        return text.isEmpty ? nil : [text]
      }
      if text.hasPrefix("[") {
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]
      }
      return text.split(separator: " ").map(String.init)
    }
  }

  func incusArguments() throws -> [[String]] {
    try commands().filter { $0.first == "remote" || $0.first == "list" }
  }

  func readState() throws -> (defaultRemote: String, remotes: [String: [String]]) {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any]
    let remotes = object?["remotes"] as? [String: [String]] ?? [:]
    return (object?["default"] as? String ?? "", remotes)
  }

  func logText() -> String {
    (try? String(contentsOf: log, encoding: .utf8)) ?? ""
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  private func writeExecutable(_ url: URL, _ contents: String) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }
}

private func jsonObject(_ text: String) throws -> [String: Any] {
  let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
  return value as? [String: Any] ?? [:]
}
