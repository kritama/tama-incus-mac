import Foundation

public struct HTTPRequest: Sendable {
  public let method: String
  public let path: String
  public let body: Data
  public static let maximumHeader = 16384
  public static let maximumBody = 1_048_576

  public static func parseHeader(_ data: Data) throws -> (String, String, Int) {
    guard data.count <= maximumHeader, let string = String(data: data, encoding: .utf8) else {
      throw RuntimeError(.invalidRequest, "Invalid or oversized HTTP header")
    }
    let lines = string.components(separatedBy: "\r\n")
    let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
    guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0",
      first[1].hasPrefix("/")
    else {
      throw RuntimeError(.invalidRequest, "Malformed request line")
    }
    var length: Int?
    for line in lines.dropFirst() where !line.isEmpty {
      guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
        throw RuntimeError(.invalidRequest, "Malformed header")
      }
      let name = String(line[..<colon]).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if name == "transfer-encoding" {
        throw RuntimeError(.invalidRequest, "Transfer encoding unsupported for control API")
      }
      if name == "content-length" {
        guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
          let count = Int(value), count <= maximumBody
        else {
          throw RuntimeError(.invalidRequest, "Ambiguous or oversized content length")
        }
        length = count
      }
    }
    return (String(first[0]), String(first[1]), length ?? 0)
  }
  public static func read(from socket: SocketDescriptor) throws -> HTTPRequest {
    var buffer = Data()
    let delimiter = Data("\r\n\r\n".utf8)
    while true {
      if let range = buffer.range(of: delimiter) {
        let (method, path, length) = try parseHeader(buffer.subdata(in: 0..<range.lowerBound))
        let start = range.upperBound
        while buffer.count - start < length {
          let chunk = try socket.read(maximum: min(65536, length - (buffer.count - start)))
          guard !chunk.isEmpty else { throw RuntimeError(.invalidRequest, "Truncated body") }
          buffer.append(chunk)
        }
        return HTTPRequest(
          method: method, path: path, body: buffer.subdata(in: start..<(start + length)))
      }
      guard buffer.count <= maximumHeader else {
        throw RuntimeError(.invalidRequest, "Header too large")
      }
      let chunk = try socket.read(maximum: 4096)
      guard !chunk.isEmpty else { throw RuntimeError(.invalidRequest, "Truncated header") }
      buffer.append(chunk)
    }
  }
}

public struct HTTPResponse: Sendable {
  public let status: Int
  public let body: Data
  public init<T: Encodable>(status: Int = 200, value: T) throws {
    self.status = status
    body = try JSON.encoder().encode(value)
  }
  public static func error(_ error: Error) -> HTTPResponse {
    struct Envelope: Encodable { let error: RuntimeError }
    let runtime = error as? RuntimeError ?? RuntimeError(.io, error.localizedDescription)
    // Envelope contains only strings/enums, which JSONEncoder can always encode.
    return try! HTTPResponse(status: runtime.httpStatus, value: Envelope(error: runtime))
  }
  public func write(to socket: SocketDescriptor) throws {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 400: reason = "Bad Request"
    case 404: reason = "Not Found"
    case 409: reason = "Conflict"
    case 504: reason = "Gateway Timeout"
    default: reason = "Service Unavailable"
    }
    try socket.write(
      Data(
        "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
          .utf8))
    try socket.write(body)
  }
}
