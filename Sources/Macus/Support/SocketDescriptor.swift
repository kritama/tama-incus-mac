import Darwin
import Foundation

/// Owns one immutable FD. Concurrent read/write/shutdown are POSIX-safe; close occurs
/// only at deinit, after every task holding this object has finished, preventing FD reuse races.
public final class SocketDescriptor: @unchecked Sendable {
  public let rawValue: Int32
  public init(_ descriptor: Int32) throws {
    guard descriptor >= 0 else { throw RuntimeError(.io, "Socket descriptor creation failed") }
    rawValue = descriptor
    var enabled: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
  }
  deinit { Darwin.close(rawValue) }
  func setNonblocking() throws {
    let flags = fcntl(rawValue, F_GETFL)
    guard flags >= 0, fcntl(rawValue, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw RuntimeError(.io, "Cannot enable nonblocking relay I/O")
    }
  }
  public func shutdown() { _ = Darwin.shutdown(rawValue, SHUT_RDWR) }
  public func shutdownWrite() { _ = Darwin.shutdown(rawValue, SHUT_WR) }
  public func timeout(seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    _ = setsockopt(
      rawValue, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(
      rawValue, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }
  public func read(maximum: Int = 65536) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: maximum)
    while true {
      let count = Darwin.read(rawValue, &buffer, buffer.count)
      if count >= 0 { return Data(buffer.prefix(count)) }
      if errno == EINTR { continue }
      throw RuntimeError(.io, "Socket read failed (errno \(errno))")
    }
  }
  public func write(_ data: Data) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(
          rawValue, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw RuntimeError(.io, "Socket write failed (errno \(errno))") }
        offset += count
      }
    }
  }
}

/// Blocking socket operations run on GCD rather than occupying Swift's cooperative executor.
public enum SocketIO {
  private static let queue = DispatchQueue(
    label: "com.upmaru.macus.io", attributes: .concurrent)
  public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try work() }) }
    }
  }
}
