import Darwin
import Foundation

struct LocalCommandResult: Sendable {
  var status: Int32
  var stdout: Data
  var stderr: Data
}

protocol LocalCommandRunner: Sendable {
  func run(
    executable: String, arguments: [String], environment: [String: String], timeout: Int
  ) async throws -> LocalCommandResult
}

/// Runs one child with fixed arguments and bounded, nonblocking pipe reads.
struct ProcessCommandRunner: LocalCommandRunner {
  static let maximumOutput = 1_048_576

  func run(
    executable: String, arguments: [String], environment: [String: String], timeout: Int
  ) async throws -> LocalCommandResult {
    try Task.checkCancellation()
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    defer {
      // Cleanup also runs when an async sleep throws on cancellation. A
      // descendant may retain the pipe writer, so never wait for pipe EOF.
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      try? output.fileHandleForReading.close()
      try? error.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
      try? error.fileHandleForWriting.close()
    }
    try makeNonblocking(output.fileHandleForReading.fileDescriptor)
    try makeNonblocking(error.fileHandleForReading.fileDescriptor)
    do { try process.run() } catch {
      throw RuntimeError(.io, "Cannot run \(URL(fileURLWithPath: executable).lastPathComponent)")
    }
    try? output.fileHandleForWriting.close()
    try? error.fileHandleForWriting.close()
    var stdout = Data()
    var stderr = Data()
    while true {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw RuntimeError(
          .timeout,
          "Command deadline exceeded: \(URL(fileURLWithPath: executable).lastPathComponent)")
      }
      try drain(output.fileHandleForReading.fileDescriptor, into: &stdout)
      try drain(error.fileHandleForReading.fileDescriptor, into: &stderr)
      if !process.isRunning {
        // Collect bytes already buffered when the direct child exited.
        try drain(output.fileHandleForReading.fileDescriptor, into: &stdout)
        try drain(error.fileHandleForReading.fileDescriptor, into: &stderr)
        return LocalCommandResult(
          status: process.terminationStatus, stdout: stdout, stderr: stderr)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func makeNonblocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw RuntimeError(.io, "Cannot configure command output pipes")
    }
  }

  private func drain(_ descriptor: Int32, into data: inout Data) throws {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    // Bound each drain so continuous stdout cannot starve stderr or deadlines.
    for _ in 0..<16 {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { return }
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        throw RuntimeError(.io, "Cannot read command output")
      }
      guard count <= Self.maximumOutput - data.count else {
        throw RuntimeError(.io, "Command output exceeded 1 MiB")
      }
      data.append(contentsOf: buffer.prefix(count))
    }
  }
}
