import Darwin
import Foundation
import os

@MainActor
public final class UnixListener {
  private let socket: SocketDescriptor
  private let source: any DispatchSourceRead
  private let path: URL
  private var connections: [UUID: SocketDescriptor] = [:]
  private var stopped = false
  private let logger = Logger(subsystem: "com.upmaru.macus", category: "unix")

  public init(path: URL, handler: @escaping @Sendable (SocketDescriptor) async -> Void) throws {
    self.path = path
    guard path.path.utf8.count < 104 else {
      throw RuntimeError(.invalidConfiguration, "Unix socket path too long")
    }
    var info = stat()
    if lstat(path.path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
        throw RuntimeError(.invalidConfiguration, "Refusing to replace unsafe socket path")
      }
      guard unlink(path.path) == 0 else { throw RuntimeError(.io, "Cannot remove stale socket") }
    }
    socket = try SocketDescriptor(Darwin.socket(AF_UNIX, SOCK_STREAM, 0))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: bytes)
    }
    let listenerFD = socket.rawValue
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0, chmod(path.path, 0o600) == 0, listen(socket.rawValue, 128) == 0,
      fcntl(socket.rawValue, F_SETFL, O_NONBLOCK) == 0
    else { throw RuntimeError(.io, "Cannot bind private Unix socket (errno \(errno))") }
    source = DispatchSource.makeReadSource(fileDescriptor: socket.rawValue, queue: .main)
    source.setEventHandler { [weak self] in
      Task { @MainActor in self?.acceptConnections(handler: handler) }
    }
    source.resume()
  }
  private func acceptConnections(handler: @escaping @Sendable (SocketDescriptor) async -> Void) {
    guard !stopped else { return }
    while true {
      let descriptor = Darwin.accept(socket.rawValue, nil, nil)
      if descriptor < 0 { break }
      guard let connection = try? SocketDescriptor(descriptor) else {
        Darwin.close(descriptor)
        continue
      }
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard connections.count < 128, getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else {
        continue
      }
      let id = UUID()
      connections[id] = connection
      Task {
        await handler(connection)
        connection.shutdown()
        connections.removeValue(forKey: id)
      }
    }
  }
  public func stop() {
    guard !stopped else { return }
    stopped = true
    source.cancel()
    socket.shutdown()
    for connection in connections.values { connection.shutdown() }
    _ = unlink(path.path)
  }
}
