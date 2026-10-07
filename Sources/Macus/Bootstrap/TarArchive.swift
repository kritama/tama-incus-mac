import Darwin
import Foundation

enum TarArchive {
  static func extract(
    tar: Data, member: String, expectedBytes: Int64, to destination: URL
  ) throws {
    try extract(
      reader: MemoryReader(tar), member: member, expectedBytes: expectedBytes, to: destination)
  }

  static func extractGzip(
    archive: URL, member: String, expectedBytes: Int64, to destination: URL,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      throw RuntimeError(.timeout, "Appliance extraction deadline exceeded")
    }
    let input = open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard input >= 0 else { throw RuntimeError(.io, "Cannot open appliance archive") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-dc"]
    let output = Pipe()
    let error = Pipe()
    process.standardInput = FileHandle(fileDescriptor: input, closeOnDealloc: true)
    process.standardOutput = output
    process.standardError = error
    defer {
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      try? output.fileHandleForReading.close()
      try? error.fileHandleForReading.close()
    }
    do { try process.run() } catch {
      throw RuntimeError(.io, "Cannot decompress appliance archive")
    }
    try? output.fileHandleForWriting.close()
    try? error.fileHandleForWriting.close()
    let reader = try PipeReader(
      descriptor: output.fileHandleForReading.fileDescriptor, deadline: deadline,
      maximumBytes: expectedBytes + 8_192)
    do {
      try extract(reader: reader, member: member, expectedBytes: expectedBytes, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    while process.isRunning {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw RuntimeError(.timeout, "Appliance extraction deadline exceeded")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard process.terminationStatus == 0 else {
      try? FileManager.default.removeItem(at: destination)
      throw RuntimeError(.invalidConfiguration, "Appliance archive decompression failed")
    }
  }

  private static func extract(
    reader: some ByteReader, member: String, expectedBytes: Int64, to destination: URL
  ) throws {
    guard expectedBytes >= 0, !member.isEmpty, !member.contains("/"), member != ".",
      member != ".."
    else { throw RuntimeError(.invalidConfiguration, "Invalid appliance member") }
    let header = try reader.readExact(512)
    if header.allSatisfy({ $0 == 0 }) {
      throw RuntimeError(.invalidConfiguration, "Appliance archive has no disk member")
    }
    let parsed = try parseHeader(header)
    guard parsed.name == member, parsed.regular, parsed.size == expectedBytes else {
      throw RuntimeError(
        .invalidConfiguration, "Appliance archive member is not the expected regular disk")
    }
    let output = open(
      destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw RuntimeError(.io, "Cannot create extracted disk") }
    var succeeded = false
    defer {
      close(output)
      if !succeeded { try? FileManager.default.removeItem(at: destination) }
    }
    var remaining = expectedBytes
    while remaining > 0 {
      let chunk = try reader.readExact(Int(min(remaining, 1024 * 1024)))
      remaining -= Int64(chunk.count)
      try writeAll(chunk, to: output)
    }
    guard fsync(output) == 0 else { throw RuntimeError(.io, "Cannot sync extracted disk") }
    let padding = (512 - (expectedBytes % 512)) % 512
    if padding > 0 { _ = try reader.readExact(Int(padding)) }
    let next = try reader.readExact(512)
    guard next.allSatisfy({ $0 == 0 }) else {
      throw RuntimeError(.invalidConfiguration, "Appliance archive contains extra members")
    }
    succeeded = true
  }

  private static func writeAll(_ chunk: Data, to descriptor: Int32) throws {
    var written = 0
    while written < chunk.count {
      let result = chunk.withUnsafeBytes { raw in
        Darwin.write(descriptor, raw.baseAddress! + written, chunk.count - written)
      }
      if result < 0 { throw RuntimeError(.io, "Cannot write extracted disk") }
      written += result
    }
  }

  private static func parseHeader(_ header: Data) throws -> (
    name: String, size: Int64, regular: Bool
  ) {
    func field(_ range: Range<Int>) -> String {
      let bytes = header[range].prefix { $0 != 0 }
      return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
    var checksumBytes = header
    for index in 148..<156 { checksumBytes[index] = 32 }
    let expected = checksumBytes.reduce(0) { $0 + Int($1) }
    let recorded = Int(field(148..<156), radix: 8) ?? -1
    guard recorded == expected else {
      throw RuntimeError(.invalidConfiguration, "Appliance archive header checksum mismatch")
    }
    let prefix = field(345..<500)
    let name = field(0..<100)
    let full = prefix.isEmpty ? name : prefix + "/" + name
    guard !full.isEmpty, full != ".", full != "..", !full.contains("\\"), !full.contains("\0"),
      !full.contains("/"), !full.contains("..")
    else { throw RuntimeError(.invalidConfiguration, "Unsafe appliance archive member name") }
    guard let size = Int64(field(124..<136), radix: 8), size >= 0 else {
      throw RuntimeError(.invalidConfiguration, "Invalid appliance archive member size")
    }
    let typeByte = header[156]
    let regular = typeByte == 0 || typeByte == UInt8(ascii: "0")
    if !regular {
      throw RuntimeError(.invalidConfiguration, "Appliance archive contains a non-regular member")
    }
    return (full, size, regular)
  }
}

private protocol ByteReader {
  func readExact(_ count: Int) throws -> Data
}

private final class MemoryReader: ByteReader {
  private let data: Data
  private var offset = 0
  init(_ data: Data) { self.data = data }
  func readExact(_ count: Int) throws -> Data {
    guard offset + count <= data.count else {
      throw RuntimeError(.invalidConfiguration, "Truncated appliance archive")
    }
    let slice = data.subdata(in: offset..<(offset + count))
    offset += count
    return slice
  }
}

private final class PipeReader: ByteReader {
  private let descriptor: Int32
  private let deadline: ContinuousClock.Instant
  private let maximumBytes: Int64
  private var produced: Int64 = 0
  init(descriptor: Int32, deadline: ContinuousClock.Instant, maximumBytes: Int64) throws {
    self.descriptor = descriptor
    self.deadline = deadline
    self.maximumBytes = maximumBytes
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw RuntimeError(.io, "Cannot configure archive output")
    }
  }
  func readExact(_ count: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw RuntimeError(.timeout, "Appliance extraction deadline exceeded")
      }
      guard produced < maximumBytes else {
        throw RuntimeError(.invalidConfiguration, "Appliance archive exceeds its size bound")
      }
      var buffer = [UInt8](repeating: 0, count: min(65_536, count - result.count))
      let readCount = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if readCount == 0 { throw RuntimeError(.invalidConfiguration, "Truncated appliance archive") }
      if readCount < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          var pollSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
          let waited = poll(&pollSet, 1, 50)
          if waited < 0 && errno != EINTR {
            throw RuntimeError(.io, "Cannot read appliance archive")
          }
          continue
        }
        throw RuntimeError(.io, "Cannot read appliance archive")
      }
      produced += Int64(readCount)
      result.append(contentsOf: buffer.prefix(readCount))
    }
    return result
  }
}
