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
    // A chunk boundary is not a line boundary. Bytes already consumed from an
    // unfinished line stay unfinished until a real newline.
    let insideLine = try startsInsideLine(url, offset: offset)
    return scan(data, from: offset, insideLine: insideLine)
  }

  private static func startsInsideLine(_ url: URL, offset: UInt64) throws -> Bool {
    guard offset > 0 else { return false }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset - 1)
    guard let previous = try handle.read(upToCount: 1) else { return false }
    return previous.first != 0x0A
  }

  private static func scan(
    _ data: Data, from offset: UInt64, insideLine: Bool
  ) -> (observations: [GuestObservation], offset: UInt64) {
    var observations: [GuestObservation] = []
    var skipping = insideLine
    var lineStart = data.startIndex
    var consumed = 0
    var index = data.startIndex
    while index < data.endIndex {
      if data[index] == 0x0A {
        if !skipping {
          let line = Data(data[lineStart...index])
          if let text = String(data: line, encoding: .utf8), let observation = parse(line: text) {
            observations.append(observation)
          }
        }
        skipping = false
        let next = data.index(after: index)
        consumed = data.distance(from: data.startIndex, to: next)
        lineStart = next
        index = next
        continue
      }
      index = data.index(after: index)
    }
    let tail = data.distance(from: lineStart, to: data.endIndex)
    if skipping || tail >= 1_024 {
      // Still inside this line. The next read must not parse its suffix.
      consumed = data.count
    }
    return (observations, offset + UInt64(consumed))
  }

  private static func isToken(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || byte == 45 || byte == 95
      }
  }
}
