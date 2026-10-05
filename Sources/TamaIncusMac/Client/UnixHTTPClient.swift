import Darwin
import Foundation

public struct LocalHTTPResponse: Sendable, Equatable {
  public let status: Int
  public let body: Data
  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}

public protocol LocalHTTPTransport: Sendable {
  func request(socket: URL, method: String, path: String, body: Data, timeout: Int) async throws
    -> LocalHTTPResponse
}

extension LocalHTTPTransport {
  public func request(socket: URL, method: String, path: String, timeout: Int) async throws
    -> LocalHTTPResponse
  {
    try await request(socket: socket, method: method, path: path, body: Data(), timeout: timeout)
  }
}

/// One bounded HTTP/1.x request on an owned nonblocking Unix socket.
///
/// Headers are limited to 16 KiB and bodies to 16 MiB. The same monotonic deadline covers
/// connect, write and read. Filesystem checks are observational: this type never creates,
/// chmods or unlinks state.
public struct UnixHTTPClient: LocalHTTPTransport, Sendable {
  public static let maximumResponseHeader = HTTPRequest.maximumHeader
  public static let maximumResponseBody = 16 * 1024 * 1024

  public init() {}

  public func request(socket: URL, method: String, path: String, body: Data = Data(), timeout: Int)
    async throws -> LocalHTTPResponse
  {
    guard socket.isFileURL, socket.path.hasPrefix("/"), socket.path.utf8.count < 104,
      !socket.path.utf8.contains(0), path.hasPrefix("/"),
      !path.utf8.contains(where: { $0 < 33 || $0 == 127 }),
      method == "GET" || method == "POST", (1...3600).contains(timeout)
    else { throw RuntimeError(.invalidRequest, "Invalid local HTTP request") }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    return try await SocketIO.run {
      try validatePrivateUnixSocket(socket)
      let descriptor = try SocketDescriptor(Darwin.socket(AF_UNIX, SOCK_STREAM, 0))
      try descriptor.setNonblocking()
      let io = ClientSocketIO(socket: descriptor, deadline: deadline)
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let bytes = Array(socket.path.utf8) + [0]
      guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw RuntimeError(
          .invalidConfiguration,
          "Unix socket path exceeds 103 bytes; choose a shorter state directory")
      }
      withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes)
      }
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor.rawValue, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      if connected != 0 {
        guard errno == EINPROGRESS || errno == EINTR else {
          throw RuntimeError(
            .unavailable, "Cannot connect to \(socket.path); start the tama-incus-mac daemon")
        }
        try io.wait(for: Int16(POLLOUT))
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor.rawValue, SOL_SOCKET, SO_ERROR, &error, &length) == 0,
          error == 0
        else { throw RuntimeError(.unavailable, "Local socket connection failed") }
      }
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(descriptor.rawValue, &uid, &gid) == 0, uid == getuid() else {
        throw RuntimeError(.invalidConfiguration, "Local socket peer must belong to this user")
      }
      let header =
        "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
      try io.write(Data(header.utf8) + body)
      var reader = ClientHTTPReader(io: io)
      return try reader.response()
    }
  }
}

/// Copies every consumed prefix into a fresh Data. Foundation Data slices can have a
/// non-zero startIndex, so integer ranges such as `0..<end` are not safe after removal.
private struct ResponseBuffer {
  private var storage = Data()
  var count: Int { storage.count }

  mutating func append(_ data: Data) {
    guard !data.isEmpty else { return }
    storage.append(data)
  }

  mutating func consume(_ count: Int) -> Data? {
    guard count >= 0, count <= storage.count else { return nil }
    let start = storage.startIndex
    let end = storage.index(start, offsetBy: count)
    let consumed = Data(storage[start..<end])
    storage = Data(storage[end..<storage.endIndex])
    return consumed
  }

  /// Returns the next CRLF-terminated line, or nil when the delimiter has not arrived.
  /// Pending bytes are bounded by `maximumPending`; a complete body may already follow it.
  mutating func consumeLine(maximumPending: Int) throws -> String? {
    let crlf = Data([0x0d, 0x0a])
    if let range = storage.range(of: crlf) {
      let length = storage.distance(from: storage.startIndex, to: range.lowerBound)
      guard length <= maximumPending else {
        throw RuntimeError(.io, "Oversized response line")
      }
      let bytes = Data(storage[storage.startIndex..<range.lowerBound])
      guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
        throw RuntimeError(.io, "Invalid response line")
      }
      storage = Data(storage[range.upperBound..<storage.endIndex])
      return text
    }
    guard storage.count <= maximumPending else {
      throw RuntimeError(.io, "Oversized response line")
    }
    return nil
  }
}

private struct ClientSocketIO {
  let socket: SocketDescriptor
  let deadline: ContinuousClock.Instant

  func wait(for events: Int16) throws {
    while true {
      let remaining = ContinuousClock.now.duration(to: deadline)
      guard remaining > .zero else {
        throw RuntimeError(.timeout, "Local API request deadline exceeded")
      }
      let parts = remaining.components
      let milliseconds = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
      let bounded = Int32(min(Int64(Int32.max), max(1, milliseconds)))
      var item = pollfd(fd: socket.rawValue, events: events, revents: 0)
      let result = Darwin.poll(&item, 1, bounded)
      if result == 0 { continue }
      if result < 0 {
        if errno == EINTR { continue }
        throw RuntimeError(.io, "Local socket polling failed")
      }
      if item.revents & Int16(POLLNVAL) != 0 {
        throw RuntimeError(.io, "Local socket polling failed")
      }
      if item.revents & events != 0 { return }
      if events & Int16(POLLIN) != 0, item.revents & Int16(POLLHUP) != 0 { return }
      if item.revents & (Int16(POLLERR) | Int16(POLLHUP)) != 0 {
        throw RuntimeError(.io, "Local socket connection failed")
      }
    }
  }

  func read() throws -> Data {
    while true {
      try wait(for: Int16(POLLIN))
      var bytes = [UInt8](repeating: 0, count: 65_536)
      let count = Darwin.read(socket.rawValue, &bytes, bytes.count)
      if count > 0 { return Data(bytes.prefix(count)) }
      if count == 0 { return Data() }
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
      throw RuntimeError(.io, "Local socket read failed")
    }
  }

  func write(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      try wait(for: Int16(POLLOUT))
      let count = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return 0 }
        return Darwin.write(socket.rawValue, base.advanced(by: offset), raw.count - offset)
      }
      if count > 0 {
        offset += count
        continue
      }
      if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
      throw RuntimeError(.io, "Local socket write failed")
    }
  }
}

private struct ClientHTTPReader {
  var io: ClientSocketIO
  var buffer = ResponseBuffer()
  private var headerBytes = 0

  mutating func response() throws -> LocalHTTPResponse {
    headerBytes = 0
    let statusLine = try headerLine()
    let first = statusLine.split(separator: " ", omittingEmptySubsequences: false)
    guard first.count >= 2, first[0] == "HTTP/1.0" || first[0] == "HTTP/1.1",
      first[1].utf8.count == 3, let status = Int(first[1]), (200...599).contains(status)
    else { throw malformed("Invalid response status") }
    var length: Int?
    var chunked = false
    while true {
      let value = try headerLine()
      if value.isEmpty { break }
      guard !value.hasPrefix(" "), !value.hasPrefix("\t"), let colon = value.firstIndex(of: ":")
      else { throw malformed("Invalid response header") }
      let name = value[..<colon].lowercased()
      guard !name.isEmpty else { throw malformed("Invalid response header") }
      let content = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if name == "content-length" {
        guard length == nil, !content.isEmpty, content.utf8.allSatisfy({ (48...57).contains($0) }),
          let size = Int(content), size <= UnixHTTPClient.maximumResponseBody
        else { throw malformed("Ambiguous or oversized response length") }
        length = size
      } else if name == "transfer-encoding" {
        guard !chunked, content.lowercased() == "chunked" else {
          throw malformed("Unsupported response transfer encoding")
        }
        chunked = true
      }
    }
    guard !(chunked && length != nil) else { throw malformed("Ambiguous response framing") }
    let body: Data
    if chunked {
      body = try chunkedBody()
    } else if let length {
      body = try exact(length)
    } else {
      body = try readUntilClose()
    }
    return LocalHTTPResponse(status: status, body: body)
  }

  private mutating func chunkedBody() throws -> Data {
    var body = Data()
    while true {
      let sizeLine = try delimitedLine(truncated: "Truncated response body")
      let sizeText = sizeLine.split(separator: ";", omittingEmptySubsequences: false)[0]
      guard !sizeText.isEmpty,
        sizeText.utf8.allSatisfy({
          (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }),
        let size = Int(sizeText, radix: 16), size <= UnixHTTPClient.maximumResponseBody - body.count
      else { throw malformed("Invalid or oversized response chunk") }
      if size == 0 {
        var trailerBytes = 0
        while true {
          let trailer = try delimitedLine(truncated: "Truncated response body")
          trailerBytes += trailer.utf8.count + 2
          guard trailerBytes <= UnixHTTPClient.maximumResponseHeader else {
            throw malformed("Oversized response trailers")
          }
          if trailer.isEmpty { break }
          guard let colon = trailer.firstIndex(of: ":"), !trailer.hasPrefix(" "),
            !trailer.hasPrefix("\t")
          else { throw malformed("Invalid response trailer") }
          let name = trailer[..<colon].lowercased()
          guard name != "content-length", name != "transfer-encoding" else {
            throw malformed("Invalid response trailer")
          }
        }
        return body
      }
      body.append(try exact(size))
      guard try exact(2) == Data("\r\n".utf8) else { throw malformed("Invalid chunk delimiter") }
    }
  }

  private mutating func readUntilClose() throws -> Data {
    var body = buffer.consume(buffer.count) ?? Data()
    while true {
      let data = try io.read()
      if data.isEmpty { return body }
      guard data.count <= UnixHTTPClient.maximumResponseBody - body.count else {
        throw malformed("Oversized response body")
      }
      body.append(data)
    }
  }

  private mutating func headerLine() throws -> String {
    let line = try delimitedLine(truncated: "Truncated response header")
    headerBytes += line.utf8.count + 2
    guard headerBytes <= UnixHTTPClient.maximumResponseHeader else {
      throw malformed("Oversized response header")
    }
    return line
  }

  private mutating func delimitedLine(truncated: String) throws -> String {
    while true {
      if let line = try buffer.consumeLine(maximumPending: UnixHTTPClient.maximumResponseHeader) {
        return line
      }
      let data = try io.read()
      guard !data.isEmpty else { throw malformed(truncated) }
      buffer.append(data)
    }
  }

  private mutating func exact(_ count: Int) throws -> Data {
    while buffer.count < count {
      let data = try io.read()
      guard !data.isEmpty else { throw malformed("Truncated response body") }
      guard data.count <= UnixHTTPClient.maximumResponseBody - buffer.count else {
        throw malformed("Oversized response body")
      }
      buffer.append(data)
    }
    guard let result = buffer.consume(count) else { throw malformed("Truncated response body") }
    return result
  }

  private func malformed(_ message: String) -> RuntimeError { RuntimeError(.io, message) }
}

func validatePrivateUnixSocket(_ endpoint: URL) throws {
  var ancestor = endpoint
  while ancestor.path != "/" {
    var info = stat()
    if lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
      if ancestor.path != endpoint.path, ["/var", "/tmp"].contains(ancestor.path),
        symlinkDestination(ancestor.path) == "private" + ancestor.path
      {
        ancestor.deleteLastPathComponent()
        continue
      }
      throw RuntimeError(.invalidConfiguration, "Symlink socket ancestry refused")
    }
    ancestor.deleteLastPathComponent()
  }
  var info = stat()
  guard lstat(endpoint.path, &info) == 0 else {
    throw RuntimeError(
      .unavailable,
      "No daemon socket at \(endpoint.path); run tama-incus-mac serve with the same state directory"
    )
  }
  guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
    throw RuntimeError(.invalidConfiguration, "Expected a private socket owned by this user")
  }
  let parent = endpoint.deletingLastPathComponent().path
  guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
    info.st_mode & 0o077 == 0
  else {
    throw RuntimeError(
      .invalidConfiguration, "Expected a private state directory owned by this user")
  }
}

private func symlinkDestination(_ path: String) -> String? {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  let count = readlink(path, &buffer, buffer.count)
  guard count >= 0, count < buffer.count else { return nil }
  let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
}
