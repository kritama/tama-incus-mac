import Darwin
import Foundation

struct GuestObservation: Sendable, Equatable {
  var stage: String
  var state: String?
  var code: String?

  var expectsKernelReboot: Bool {
    stage == "kernel_transition" && state == "expected_reboot"
  }

  var failed: Bool { stage == "failed" }
}

enum GuestObservationParser {
  static let stages: Set<String> = [
    "packages", "kernel_transition", "storage", "incus", "failed", "ready",
  ]
  static let legacyReboot = "TAMA_ZFS_KERNEL_REBOOT_REQUIRED"

  static func parse(line: String) -> GuestObservation? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == legacyReboot {
      return GuestObservation(stage: "kernel_transition", state: "expected_reboot", code: nil)
    }
    let prefix = "MACUS_OBSERVATION "
    guard trimmed.hasPrefix(prefix) else { return nil }
    let parts = trimmed.dropFirst(prefix.count).split(separator: " ")
    guard let version = parts.first, version == "v1" else { return nil }
    var fields: [String: String] = [:]
    for part in parts.dropFirst() {
      let pair = part.split(separator: "=", maxSplits: 1)
      guard pair.count == 2 else { return nil }
      let key = String(pair[0])
      let value = String(pair[1])
      guard !key.isEmpty, isToken(value), fields[key] == nil else { return nil }
      fields[key] = value
    }
    guard let stage = fields["stage"], stages.contains(stage) else { return nil }
    return GuestObservation(stage: stage, state: fields["state"], code: fields["code"])
  }

  static func parse(text: String) -> [GuestObservation] {
    text.split(whereSeparator: \.isNewline).compactMap { parse(line: String($0)) }
  }

  static func endOffset(_ url: URL) throws -> UInt64 {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      guard errno == ENOENT else { throw RuntimeError(.io, "Cannot inspect serial log") }
      return 0
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size >= 0 else {
      throw RuntimeError(.invalidConfiguration, "Serial log is not an owned regular file")
    }
    return UInt64(info.st_size)
  }

  static func read(url: URL, from offset: UInt64) throws -> (
    observations: [GuestObservation], offset: UInt64
  ) {
    var info = stat()
    if lstat(url.path, &info) != 0 {
      guard errno == ENOENT else { throw RuntimeError(.io, "Cannot inspect serial log") }
      return ([], offset)
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size >= 0 else {
      throw RuntimeError(.invalidConfiguration, "Serial log is not an owned regular file")
    }
    let end = UInt64(info.st_size)
    guard end > offset else { return ([], offset) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    let length = Int(min(end - offset, 65_536))
    guard let data = try handle.read(upToCount: length), !data.isEmpty else { return ([], offset) }
    guard let text = String(data: data, encoding: .utf8) else {
      return ([], offset + UInt64(data.count))
    }
    guard let newline = text.lastIndex(of: "\n") else {
      if data.count >= 512 { return ([], offset + UInt64(data.count)) }
      return ([], offset)
    }
    let complete = text[...newline]
    let consumed = Data(complete.utf8).count
    return (parse(text: String(complete)), offset + UInt64(consumed))
  }

  private static func isToken(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || byte == 45 || byte == 95
      }
  }
}
