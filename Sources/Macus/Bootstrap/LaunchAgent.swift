import CryptoKit
import Darwin
import Foundation

struct LaunchJob: Sendable, Equatable {
  var label: String
  var loaded: Bool
  var programArguments: [String]
}

protocol LaunchControl: Sendable {
  func printJob(label: String, timeout: Int) async throws -> LaunchJob?
  func bootstrap(plist: URL, timeout: Int) async throws
  func plist(at url: URL) throws -> [String: Any]?
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
    let text =
      String(decoding: result.stdout, as: UTF8.self)
      + String(decoding: result.stderr, as: UTF8.self)
    return LaunchJob(
      label: label,
      loaded: !text.contains("state = not running") || text.contains("state = running"),
      programArguments: [])
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
