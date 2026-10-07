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
    if FileManager.default.fileExists(atPath: file.path) { return }
    try write(RebootAllowance(state: "available", catalogId: catalogID), to: file)
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
    try write(RebootAllowance(state: "consumed", catalogId: existing.catalogId), to: file)
  }

  private static func write(_ value: RebootAllowance, to file: URL) throws {
    try JSON.encoder().encode(value).write(to: file, options: .atomic)
    guard chmod(file.path, 0o600) == 0 else {
      throw RuntimeError(.io, "Cannot secure reboot allowance; no automatic restart was attempted")
    }
  }
}
