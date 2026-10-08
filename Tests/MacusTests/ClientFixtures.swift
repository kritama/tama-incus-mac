import Darwin
import Foundation
import Testing

@testable import Macus

final class PrivateUNIXSocket: @unchecked Sendable {
  let directory: URL
  let url: URL
  private var listener: Int32 = -1
  private let lock = NSLock()
  private var stopped = false
  private var started = false
  private let finished = DispatchSemaphore(value: 0)
  private let accepted = NSLock()
  private var acceptCount = 0

  init(name: String = "endpoint.sock", directory: URL? = nil) throws {
    if let directory {
      self.directory = directory
    } else {
      self.directory = URL(
        fileURLWithPath: "/tmp/macus\(UUID().uuidString.prefix(8))", isDirectory: true)
    }
    try FileManager.default.createDirectory(
      at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard chmod(self.directory.path, 0o700) == 0 else {
      throw RuntimeError(.io, "Cannot secure test directory")
    }
    url = self.directory.appendingPathComponent(name)
    listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw RuntimeError(.io, "socket failed") }
    var enabled: Int32 = 1
    _ = setsockopt(
      listener, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(url.path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw RuntimeError(.invalidConfiguration, "Test socket path exceeds 103 bytes")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let descriptor = listener
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(url.path, 0o600) == 0, listen(listener, 16) == 0 else {
      throw RuntimeError(.io, "Cannot bind test socket (errno \(errno))")
    }
  }

  var accepts: Int {
    accepted.lock()
    defer { accepted.unlock() }
    return acceptCount
  }

  func serve(_ handler: @escaping @Sendable (Int32) -> Void) {
    let descriptor = listener
    started = true
    DispatchQueue.global(qos: .userInitiated).async {
      while !self.isStopped {
        let client = Darwin.accept(descriptor, nil, nil)
        if client < 0 { break }
        self.accepted.lock()
        self.acceptCount += 1
        self.accepted.unlock()
        var enabled: Int32 = 1
        _ = setsockopt(
          client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        handler(client)
      }
      self.finished.signal()
    }
  }

  /// Consume the complete request before responding so close cannot race the client's write.
  /// SocketDescriptor owns the accepted descriptor; HTTP handlers must not close it themselves.
  func serveHTTP(_ handler: @escaping @Sendable (HTTPRequest, Int32) -> Void) {
    serve { descriptor in
      do {
        let connection = try SocketDescriptor(descriptor)
        connection.timeout(seconds: 3)
        let request = try HTTPRequest.read(from: connection)
        withExtendedLifetime(connection) { handler(request, descriptor) }
      } catch {
        Issue.record("HTTP fixture could not read the request: \(error)")
      }
    }
  }

  var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  func stop() {
    lock.lock()
    stopped = true
    let descriptor = listener
    listener = -1
    lock.unlock()
    if descriptor >= 0 { Darwin.close(descriptor) }
    if started { _ = finished.wait(timeout: .now() + 2) }
    unlink(url.path)
    try? FileManager.default.removeItem(at: directory)
  }

  func sleepOrStop(_ seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if isStopped { return false }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return !isStopped
  }
}

func writeAll(_ descriptor: Int32, _ data: Data) {
  data.withUnsafeBytes { raw in
    guard let base = raw.baseAddress, raw.count > 0 else { return }
    var offset = 0
    while offset < raw.count {
      let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
      if count > 0 {
        offset += count
        continue
      }
      return
    }
  }
}

func httpMessage(status: String = "HTTP/1.1 200 OK", headers: [String], body: Data = Data()) -> Data
{
  var text = status + "\r\n"
  if !headers.isEmpty { text += headers.joined(separator: "\r\n") + "\r\n" }
  text += "\r\n"
  var data = Data(text.utf8)
  data.append(body)
  return data
}

func mustJSON(_ status: Int, _ object: Any) -> Data {
  guard let data = try? jsonHTTP(status: status, object: object) else { return Data() }
  return data
}

func jsonHTTP(status: Int, object: Any) throws -> Data {
  let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  let reason: String
  switch status {
  case 200: reason = "OK"
  case 404: reason = "Not Found"
  case 409: reason = "Conflict"
  case 503: reason = "Service Unavailable"
  default: reason = "Error"
  }
  return httpMessage(
    status: "HTTP/1.1 \(status) \(reason)",
    headers: [
      "Content-Type: application/json", "Content-Length: \(body.count)", "Connection: close",
    ], body: body)
}

struct CLIResult {
  var status: Int32
  var stdout: String
  var stderr: String
  var elapsed: Duration
}

func macusExecutable() throws -> URL {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let candidates = [
    root.appendingPathComponent(".build/debug/macus"),
    root.appendingPathComponent(".build/arm64-apple-macosx/debug/macus"),
  ]
  if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
  {
    return match
  }
  var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
  for _ in 0..<6 {
    let candidate = directory.appendingPathComponent("macus")
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    directory.deleteLastPathComponent()
  }
  throw RuntimeError(.unavailable, "Build the macus executable before executable tests")
}

func runMacus(_ arguments: [String], environment: [String: String] = [:]) async throws -> CLIResult
{
  var env = ProcessInfo.processInfo.environment
  env.removeValue(forKey: "MACUS_STATE_DIR")
  env.removeValue(forKey: "TIM_STATE_DIR")
  for (key, value) in environment { env[key] = value }
  let started = ContinuousClock.now
  let result = try await ProcessCommandRunner().run(
    executable: macusExecutable().path, arguments: arguments, environment: env, timeout: 20)
  return CLIResult(
    status: result.status,
    stdout: String(decoding: result.stdout, as: UTF8.self),
    stderr: String(decoding: result.stderr, as: UTF8.self),
    elapsed: started.duration(to: .now))
}

final class ScriptedSocket: @unchecked Sendable {
  let socket: PrivateUNIXSocket
  private let lock = NSLock()
  private var recorded: [(method: String, path: String, body: Data)] = []
  var responder: @Sendable (String, String, Data) -> Data
  var delay: Double = 0

  init(
    name: String, directory: URL? = nil,
    responder: @escaping @Sendable (String, String, Data) -> Data
  ) throws {
    socket = try PrivateUNIXSocket(name: name, directory: directory)
    self.responder = responder
    socket.serve { [self] descriptor in
      do {
        let connection = try SocketDescriptor(descriptor)
        connection.timeout(seconds: 3)
        let request = try HTTPRequest.read(from: connection)
        self.lock.lock()
        self.recorded.append((request.method, request.path, request.body))
        let delay = self.delay
        let responder = self.responder
        self.lock.unlock()
        if delay > 0, !self.socket.sleepOrStop(delay) { return }
        try connection.write(responder(request.method, request.path, request.body))
      } catch {
        return
      }
    }
  }

  func requests() -> [(method: String, path: String, body: Data)] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func stop() { socket.stop() }
}

func statusObject(state: String, incus: String) -> [String: Any] {
  [
    "api_version": 1, "incus_socket": incus, "last_error": NSNull(), "state": state,
    "uptime_seconds": 4,
  ]
}

func errorObject(code: String, message: String) -> [String: Any] {
  ["error": ["code": code, "message": message]]
}
