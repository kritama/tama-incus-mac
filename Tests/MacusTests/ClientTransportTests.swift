import Darwin
import Foundation
import Testing

@testable import Macus

@Test func contentLengthAndSplitReads() async throws {
  let server = try PrivateUNIXSocket()
  defer { server.stop() }
  let body = Data("hello-index".utf8)
  let message = httpMessage(
    headers: ["Content-Length: \(body.count)", "Connection: close"], body: body)
  server.serveHTTP { _, descriptor in
    writeAll(descriptor, Data(message.prefix(8)))
    Thread.sleep(forTimeInterval: 0.05)
    writeAll(descriptor, Data(message.dropFirst(8)))
  }
  let response = try await UnixHTTPClient().request(
    socket: server.url, method: "GET", path: "/v1/runtime/status", timeout: 10)
  #expect(response.status == 200)
  #expect(response.body == body)
}

@Test(arguments: [2, 256 * 1024])
func chunkedFramingSurvivesByteSizedReads(requestBodySize: Int) async throws {
  let server = try PrivateUNIXSocket()
  defer { server.stop() }
  let requestBody = Data(repeating: 0x41, count: requestBodySize)
  let raw = Data(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n1;ext=1\r\n!\r\n0\r\nX-Trace: ok\r\n\r\n"
      .utf8)
  server.serveHTTP { request, descriptor in
    #expect(request.method == "POST")
    #expect(request.path == "/v1/runtime/stop")
    #expect(request.body == requestBody)
    for byte in raw { writeAll(descriptor, Data([byte])) }
  }
  let response = try await UnixHTTPClient().request(
    socket: server.url, method: "POST", path: "/v1/runtime/stop", body: requestBody, timeout: 10
  )
  #expect(response.status == 200)
  #expect(response.body == Data("hello!".utf8))
}

@Test func connectionCloseWithoutLength() async throws {
  let server = try PrivateUNIXSocket()
  defer { server.stop() }
  server.serveHTTP { _, descriptor in
    writeAll(descriptor, Data("HTTP/1.0 200 OK\r\nConnection: close\r\n\r\nbye".utf8))
  }
  let response = try await UnixHTTPClient().request(
    socket: server.url, method: "GET", path: "/health", timeout: 10)
  #expect(response.body == Data("bye".utf8))
}

@Test func malformedTruncatedAndAmbiguousFramingRejected() async throws {
  let cases: [Data] = [
    Data("NOTHTTP\r\n\r\n".utf8),
    httpMessage(headers: ["Content-Length: 10"], body: Data("abc".utf8)),
    httpMessage(headers: ["Content-Length: 1", "Content-Length: 1"], body: Data("Z".utf8)),
    httpMessage(
      headers: ["Content-Length: 1", "Transfer-Encoding: chunked"],
      body: Data("1\r\nZ\r\n0\r\n\r\n".utf8)),
    Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8),
    Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nZ".utf8),
    httpMessage(headers: ["Content-Length: 16777217"]),
    Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1000001\r\n".utf8),
    Data(("HTTP/1.1 200 OK\r\nX-" + String(repeating: "A", count: 17_000) + "\r\n\r\n").utf8),
  ]
  for message in cases {
    let server = try PrivateUNIXSocket()
    defer { server.stop() }
    server.serveHTTP { _, descriptor in
      writeAll(descriptor, message)
    }
    await #expect(throws: RuntimeError.self) {
      try await UnixHTTPClient().request(
        socket: server.url, method: "GET", path: "/v1/x", timeout: 10)
    }
  }
}

@Test func manyHeaderLinesShareOneBudget() async throws {
  let server = try PrivateUNIXSocket()
  defer { server.stop() }
  let headers = (0..<20).map { "X-\($0): \(String(repeating: "B", count: 1000))" }
  server.serveHTTP { _, descriptor in
    writeAll(descriptor, httpMessage(headers: headers, body: Data("Z".utf8)))
  }
  do {
    _ = try await UnixHTTPClient().request(
      socket: server.url, method: "GET", path: "/v1/x", timeout: 10)
    Issue.record("Oversized headers were accepted")
  } catch let error as RuntimeError {
    #expect(error.code == .io)
  }
}

@Test func delayedPeerUsesOneTotalDeadline() async throws {
  let handlerStarted = HandlerObservation()
  let server = try PrivateUNIXSocket()
  defer { server.stop() }
  server.serveHTTP { _, descriptor in
    handlerStarted.markStarted()
    _ = server.sleepOrStop(3)
    writeAll(descriptor, httpMessage(headers: ["Content-Length: 1"], body: Data("Z".utf8)))
  }
  let started = ContinuousClock.now
  do {
    _ = try await UnixHTTPClient().request(
      socket: server.url, method: "GET", path: "/v1/x", timeout: 1)
    Issue.record("Delayed peer succeeded")
  } catch let error as RuntimeError {
    #expect(error.code == .timeout)
  }
  #expect(handlerStarted.didStart)
  #expect(started.duration(to: .now) < .milliseconds(2_200))
}

@Test func trickledBytesDoNotResetTheDeadline() async throws {
  let handlerStarted = HandlerObservation()
  let server = try PrivateUNIXSocket()
  defer { server.stop() }
  let message = httpMessage(headers: ["Content-Length: 4"], body: Data("ABCD".utf8))
  server.serveHTTP { _, descriptor in
    handlerStarted.markStarted()
    writeAll(descriptor, Data(message.prefix(1)))
    guard server.sleepOrStop(0.6) else { return }
    writeAll(descriptor, Data(message.dropFirst(1).prefix(1)))
    guard server.sleepOrStop(0.6) else { return }
    writeAll(descriptor, Data(message.dropFirst(2)))
  }
  let started = ContinuousClock.now
  do {
    _ = try await UnixHTTPClient().request(
      socket: server.url, method: "GET", path: "/v1/x", timeout: 1)
    Issue.record("Per-read deadlines would have accepted this trickle")
  } catch let error as RuntimeError {
    #expect(error.code == .timeout)
  }
  #expect(handlerStarted.didStart)
  #expect(started.duration(to: .now) < .milliseconds(1_800))
}

@Test func unsafeSocketPathsAreRejectedWithoutMutation() async throws {
  let server = try PrivateUNIXSocket()
  defer { server.stop() }
  let link = server.directory.appendingPathComponent("linked.sock")
  #expect(symlink(server.url.path, link.path) == 0)
  do {
    _ = try await UnixHTTPClient().request(socket: link, method: "GET", path: "/v1/x", timeout: 1)
    Issue.record("Symlink socket was accepted")
  } catch let error as RuntimeError {
    #expect(error.code == .invalidConfiguration)
    #expect(error.message.contains("Symlink"))
  }

  let ancestor = server.directory.deletingLastPathComponent().appendingPathComponent(
    "ancestor-\(UUID().uuidString)")
  #expect(symlink(server.directory.path, ancestor.path) == 0)
  defer { unlink(ancestor.path) }
  let throughLink = ancestor.appendingPathComponent(server.url.lastPathComponent)
  do {
    _ = try await UnixHTTPClient().request(
      socket: throughLink, method: "GET", path: "/v1/x", timeout: 1)
    Issue.record("Symlink ancestor was accepted")
  } catch let error as RuntimeError {
    #expect(error.code == .invalidConfiguration)
  }

  #expect(chmod(server.url.path, 0o666) == 0)
  do {
    _ = try await UnixHTTPClient().request(
      socket: server.url, method: "GET", path: "/v1/x", timeout: 1)
    Issue.record("Group-accessible socket was accepted")
  } catch let error as RuntimeError {
    #expect(error.code == .invalidConfiguration)
  }
  #expect(chmod(server.url.path, 0o600) == 0)
  #expect(chmod(server.directory.path, 0o755) == 0)
  do {
    _ = try await UnixHTTPClient().request(
      socket: server.url, method: "GET", path: "/v1/x", timeout: 1)
    Issue.record("Loose state directory was accepted")
  } catch let error as RuntimeError {
    #expect(error.code == .invalidConfiguration)
  }
  var info = stat()
  #expect(lstat(server.directory.path, &info) == 0)
  #expect(info.st_mode & 0o777 == 0o755)
}

@Test func missingAndNonSocketEndpointsDoNotCreateFiles() async throws {
  let root = URL(fileURLWithPath: "/tmp/timm\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let missing = root.appendingPathComponent("runtime.sock")
  do {
    _ = try await UnixHTTPClient().request(
      socket: missing, method: "GET", path: "/v1/x", timeout: 1)
    Issue.record("Missing socket succeeded")
  } catch let error as RuntimeError {
    #expect(error.code == .unavailable)
    #expect(error.message.contains("macus serve"))
  }
  #expect(!FileManager.default.fileExists(atPath: missing.path))
  let file = root.appendingPathComponent("not-a-socket")
  FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8), attributes: nil)
  #expect(chmod(file.path, 0o600) == 0)
  do {
    _ = try await UnixHTTPClient().request(socket: file, method: "GET", path: "/v1/x", timeout: 1)
    Issue.record("Regular file was accepted")
  } catch let error as RuntimeError {
    #expect(error.code == .invalidConfiguration)
  }
}

@Test func unsafeRequestPathDoesNotConnect() async throws {
  let server = try PrivateUNIXSocket()
  defer { server.stop() }
  server.serve { descriptor in Darwin.close(descriptor) }
  do {
    _ = try await UnixHTTPClient().request(
      socket: server.url, method: "GET", path: "/bad\npath", timeout: 1)
    Issue.record("Header injection path was accepted")
  } catch let error as RuntimeError {
    #expect(error.code == .invalidRequest)
  }
  try await Task.sleep(for: .milliseconds(50))
  #expect(server.accepts == 0)
}

private final class HandlerObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false

  func markStarted() {
    lock.lock()
    defer { lock.unlock() }
    started = true
  }

  var didStart: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started
  }
}
