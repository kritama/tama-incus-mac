import Darwin
import Foundation

struct RebootAllowance: Codable, Sendable, Equatable {
  var schemaVersion: Int = 1
  var state: String
  var catalogId: String
}

enum RebootAllowanceStore {
  static func url(_ paths: RuntimePaths) -> URL {
    paths.directory.appendingPathComponent("reboot-allowance.json")
  }

  static func ensureAvailable(paths: RuntimePaths, catalogID: String) throws {
    let file = url(paths)
    if try existingAllowance(file) != nil { return }
    try write(RebootAllowance(state: "available", catalogId: catalogID), to: file, exclusive: true)
  }

  /// Confirmed reset may remove the allowance only after proving it is an owned regular file.
  /// A symlink or foreign file fails closed and must not be followed.
  static func rejectUnsafeForConfirmedReset(paths: RuntimePaths) throws {
    _ = try existingAllowance(url(paths))
  }

  static func removeAfterConfirmedReset(paths: RuntimePaths) throws {
    let file = url(paths)
    guard try existingAllowance(file) != nil else { return }
    guard unlink(file.path) == 0 else {
      throw RuntimeError(
        .io, "Cannot remove reboot allowance after confirmed reset; runtime data was preserved")
    }
  }

  static func state(paths: RuntimePaths) throws -> String? {
    let file = url(paths)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    try requireOwnedRegular(file)
    let value = try JSON.decoder().decode(RebootAllowance.self, from: Data(contentsOf: file))
    guard value.schemaVersion == 1, value.state == "available" || value.state == "consumed" else {
      throw RuntimeError(
        .io, "Reboot allowance bookkeeping is invalid; no automatic restart was attempted")
    }
    return value.state
  }

  static func consume(paths: RuntimePaths) throws {
    let file = url(paths)
    guard let current = try state(paths: paths) else {
      throw RuntimeError(.unavailable, "No fresh-bootstrap reboot allowance is recorded")
    }
    guard current == "available" else {
      throw RuntimeError(
        .unavailable,
        "The fresh-bootstrap kernel restart was already used. Start again manually or inspect serial.log; the runtime was not deleted."
      )
    }
    let existing = try JSON.decoder().decode(RebootAllowance.self, from: Data(contentsOf: file))
    try write(
      RebootAllowance(state: "consumed", catalogId: existing.catalogId), to: file, exclusive: false)
  }

  private static func existingAllowance(_ file: URL) throws -> stat? {
    var info = stat()
    if lstat(file.path, &info) != 0 {
      guard errno == ENOENT else {
        throw RuntimeError(.io, "Cannot inspect reboot allowance")
      }
      return nil
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
      throw RuntimeError(
        .invalidConfiguration,
        "Reboot allowance bookkeeping is unsafe; runtime data was preserved")
    }
    return info
  }

  private static func write(_ value: RebootAllowance, to file: URL, exclusive: Bool) throws {
    if try existingAllowance(file) != nil {
      guard !exclusive else {
        throw RuntimeError(
          .conflict, "Reboot allowance already exists; it was not replenished")
      }
    }
    let data = try JSON.encoder().encode(value)
    let temporary = file.deletingLastPathComponent().appendingPathComponent(
      ".reboot-allowance-\(UUID().uuidString)")
    let descriptor = open(
      temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw RuntimeError(.io, "Cannot secure reboot allowance; no automatic restart was attempted")
    }
    defer { close(descriptor) }
    var written = 0
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else {
        throw RuntimeError(
          .io, "Cannot secure reboot allowance; no automatic restart was attempted")
      }
      while written < data.count {
        let result = Darwin.write(descriptor, base.advanced(by: written), data.count - written)
        if result < 0 {
          throw RuntimeError(
            .io, "Cannot secure reboot allowance; no automatic restart was attempted")
        }
        written += result
      }
    }
    guard fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else {
      _ = unlink(temporary.path)
      throw RuntimeError(.io, "Cannot secure reboot allowance; no automatic restart was attempted")
    }
  }
}
