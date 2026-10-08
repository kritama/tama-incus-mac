import CryptoKit
import Darwin
import Foundation

struct LaunchJob: Sendable, Equatable {
  var label: String
  /// True when launchctl reports the job running or starting. A registered stopped job is false.
  var loaded: Bool
  var executable: String
  var programArguments: [String]
}

protocol LaunchControl: Sendable {
  func printJob(label: String, timeout: Int) async throws -> LaunchJob?
  func bootstrap(plist: URL, timeout: Int) async throws
  func kickstart(label: String, timeout: Int) async throws
  func plist(at url: URL) throws -> [String: Any]?
}

enum LaunchJobParser {
  /// Reads authoritative identity from `launchctl print` text. A chunk boundary or disk plist is not a source.
  static func parse(text: String, label: String) throws -> LaunchJob {
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(
      String.init)
    let arguments = try argumentBlocks(lines, label: label)
    let states = lines.compactMap { stateValue($0, indentation: arguments.indentation) }
    guard states.count == 1, let state = states.first else {
      throw ambiguous(label)
    }
    let loaded: Bool
    switch state {
    case "not running":
      loaded = false
    case "running", "spawn scheduled", "starting", "xpcproxy":
      loaded = true
    default:
      throw ambiguous(label)
    }
    let programPrefix = arguments.indentation + "program = "
    let programs = lines.filter { $0.hasPrefix(programPrefix) }.map {
      String($0.dropFirst(programPrefix.count))
    }
    guard programs.count == 1, let executable = programs.first,
      isAbsoluteExecutablePath(executable)
    else { throw ambiguous(label) }
    return LaunchJob(
      label: label, loaded: loaded, executable: executable, programArguments: arguments.values)
  }

  private static func stateValue(_ line: String, indentation: String) -> String? {
    let prefix = indentation + "state = "
    guard line.hasPrefix(prefix) else { return nil }
    let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : value
  }

  private static func argumentBlocks(_ lines: [String], label: String) throws -> (
    values: [String], indentation: String
  ) {
    var blocks: [(values: [String], indentation: String)] = []
    var index = 0
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      guard trimmed == "arguments = {" else {
        index += 1
        continue
      }
      let blockIndentation = String(lines[index].prefix { $0 == "\t" || $0 == " " })
      let argumentIndentation = blockIndentation + "\t"
      var arguments: [String] = []
      var closed = false
      index += 1
      while index < lines.count {
        let line = lines[index]
        if line == blockIndentation + "}" {
          closed = true
          break
        }
        guard line.hasPrefix(argumentIndentation) else { throw ambiguous(label) }
        // Remove only launchctl's indentation; whitespace in argv is significant.
        let argument = String(line.dropFirst(argumentIndentation.count))
        guard !argument.isEmpty else { throw ambiguous(label) }
        arguments.append(argument)
        index += 1
      }
      guard closed, !arguments.isEmpty else { throw ambiguous(label) }
      blocks.append((arguments, blockIndentation))
      index += 1
    }
    guard blocks.count == 1, let arguments = blocks.first else { throw ambiguous(label) }
    return arguments
  }

  private static func ambiguous(_ label: String) -> RuntimeError {
    RuntimeError(
      .invalidConfiguration,
      "launchctl did not report an unambiguous executable and state for \(label). macus start will not start or replace that service."
    )
  }
}

struct ProcessLaunchControl: LaunchControl {
  var runner: any LocalCommandRunner
  var environment: [String: String]
  var uid: uid_t

  func printJob(label: String, timeout: Int) async throws -> LaunchJob? {
    let result = try await runner.run(
      executable: "/bin/launchctl", arguments: ["print", "gui/\(uid)/\(label)"],
      environment: environment, timeout: timeout)
    guard result.status == 0 else { return nil }
    let text = String(decoding: result.stdout, as: UTF8.self)
    return try LaunchJobParser.parse(text: text, label: label)
  }

  func kickstart(label: String, timeout: Int) async throws {
    let result = try await runner.run(
      executable: "/bin/launchctl", arguments: ["kickstart", "gui/\(uid)/\(label)"],
      environment: environment, timeout: timeout)
    guard result.status == 0 else {
      let detail = terminalSafe(
        String(decoding: result.stderr, as: UTF8.self).prefix(500).description)
      throw RuntimeError(
        .io, "launchctl kickstart failed\(detail.isEmpty ? "" : ": \(detail)")")
    }
  }

  func bootstrap(plist: URL, timeout: Int) async throws {
    let result = try await runner.run(
      executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", plist.path],
      environment: environment, timeout: timeout)
    guard result.status == 0 else {
      let detail = terminalSafe(
        String(decoding: result.stderr, as: UTF8.self).prefix(500).description)
      throw RuntimeError(.io, "launchctl bootstrap failed\(detail.isEmpty ? "" : ": \(detail)")")
    }
  }

  func plist(at url: URL) throws -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    try requireOwnedRegular(url)
    let object = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: url), options: [], format: nil)
    return object as? [String: Any]
  }
}

enum LaunchAgentPlan {
  static func label(stateDirectory: URL, home: URL) -> String {
    if isDefault(stateDirectory, home: home) { return "com.upmaru.macus" }
    let digest = SHA256.hash(data: Data(stateDirectory.standardizedFileURL.path.utf8))
    let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    return "com.upmaru.macus.\(hex)"
  }

  static func isDefault(_ directory: URL, home: URL) -> Bool {
    directory.standardizedFileURL.path
      == home.appendingPathComponent(".tama/incus-mac").standardizedFileURL.path
  }

  static func plistURL(stateDirectory: URL, home: URL, launchAgents: URL) -> URL {
    let label = label(stateDirectory: stateDirectory, home: home)
    if isDefault(stateDirectory, home: home) {
      return launchAgents.appendingPathComponent("\(label).plist")
    }
    return stateDirectory.appendingPathComponent("launchd", isDirectory: true)
      .appendingPathComponent("\(label).plist")
  }

  static func arguments(executable: String, stateDirectory: URL) -> [String] {
    [executable, "serve", "--state-dir", stateDirectory.standardizedFileURL.path]
  }

  static func write(
    stateDirectory: URL, home: URL, launchAgents: URL, executable: String
  ) throws -> URL {
    let label = label(stateDirectory: stateDirectory, home: home)
    guard label == "com.upmaru.macus" || label.hasPrefix("com.upmaru.macus.") else {
      throw RuntimeError(.invalidConfiguration, "Refusing an unsafe service label")
    }
    let plist = plistURL(stateDirectory: stateDirectory, home: home, launchAgents: launchAgents)
    let expected = arguments(executable: executable, stateDirectory: stateDirectory)
    // A conflicting registration at this exact path must survive even if an earlier scan missed it.
    if try destinationExists(plist) {
      try refuseConflictingDestination(plist, label: label, arguments: expected)
      return plist
    }
    let logs = stateDirectory.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(
      at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try createOwnedDirectory(plist.deletingLastPathComponent())
    let object: [String: Any] = [
      "Label": label,
      "ProgramArguments": expected,
      "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false],
      "ThrottleInterval": 10,
      "ExitTimeOut": 90,
      "ProcessType": "Background",
      "StandardOutPath": logs.appendingPathComponent("service.out.log").path,
      "StandardErrorPath": logs.appendingPathComponent("service.err.log").path,
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: object, format: .xml, options: 0)
    let descriptor = open(
      plist.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    if descriptor < 0 {
      if errno == EEXIST || errno == ELOOP {
        try refuseConflictingDestination(plist, label: label, arguments: expected)
        return plist
      }
      throw RuntimeError(.io, "Cannot create service plist")
    }
    defer { close(descriptor) }
    var written = 0
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else {
        throw RuntimeError(.io, "Cannot write service plist")
      }
      while written < data.count {
        let result = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
        if result < 0 { throw RuntimeError(.io, "Cannot write service plist") }
        written += result
      }
    }
    guard fsync(descriptor) == 0 else { throw RuntimeError(.io, "Cannot sync service plist") }
    return plist
  }

  /// Rejects a same-label plist that names another executable or state, and any symlink or
  /// foreign destination. A byte-for-byte compatible registration is left untouched.
  static func refuseConflictingDestination(
    _ url: URL, label: String, arguments expected: [String]
  ) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT { return }
      throw RuntimeError(.io, "Cannot inspect service plist")
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
      throw RuntimeError(
        .invalidConfiguration,
        "Refusing an unsafe service plist destination: \(url.path)")
    }
    let object =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), options: [], format: nil) as? [String: Any]
    let existingLabel = object?["Label"] as? String
    let existingArguments = object?["ProgramArguments"] as? [String]
    guard existingLabel == label, existingArguments == expected else {
      throw RuntimeError(
        .conflict,
        "Service \(label) already points at a different executable or state. macus start will not replace that plist."
      )
    }
  }

  private static func destinationExists(_ url: URL) throws -> Bool {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      guard errno == ENOENT else { throw RuntimeError(.io, "Cannot inspect service plist") }
      return false
    }
    return true
  }

  private static func createOwnedDirectory(_ url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
        throw RuntimeError(
          .invalidConfiguration, "Refusing an unsafe service plist directory: \(url.path)")
      }
      return
    }
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  static func targets(_ arguments: [String], stateDirectory: URL) -> Bool {
    arguments.contains(stateDirectory.standardizedFileURL.path)
  }
}

enum LegacyService {
  static let labels = ["com.kritama.macus", "com.kritama.tama-incus-mac"]
}
