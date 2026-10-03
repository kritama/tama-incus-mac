import Darwin
import Foundation
import Testing

@testable import TamaIncusMac

@Test(arguments: [
  "POST /v1/runtime/start HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0",
  "POST /v1/runtime/start HTTP/1.1\r\nTransfer-Encoding: chunked",
  "POST /v1/runtime/start HTTP/1.1\r\nContent-Length: -1",
  "POST /v1/runtime/start HTTP/1.1\r\nContent-Length: 1048577",
  "POST /v1/runtime/start HTTP/1.1\r\n Content-Length: 0",
]) func ambiguousHTTPRejected(header: String) {
  #expect(throws: RuntimeError.self) { try HTTPRequest.parseHeader(Data(header.utf8)) }
}

@Test func validHTTPFrame() throws {
  let (method, path, size) = try HTTPRequest.parseHeader(
    Data("PUT /v1/runtime/config HTTP/1.1\r\nHost: local\r\nContent-Length: 2".utf8))
  #expect(method == "PUT" && path == "/v1/runtime/config" && size == 2)
}

func socketPair() throws -> (SocketDescriptor, SocketDescriptor) {
  var descriptors: [Int32] = [0, 0]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
    throw RuntimeError(.io, "socketpair failed")
  }
  return try (SocketDescriptor(descriptors[0]), SocketDescriptor(descriptors[1]))
}

@Test @MainActor func unresponsiveGuestConnectionHasDeadline() async throws {
  let attempt = GuestConnectionAttempt()
  let began = ContinuousClock.now
  do {
    _ = try await attempt.wait(timeout: .milliseconds(20)) { _ in }
    Issue.record("An unresponsive connection unexpectedly succeeded")
  } catch let error as RuntimeError {
    #expect(error.code == .timeout)
  }
  #expect(began.duration(to: .now) < .seconds(2))
  #expect(!attempt.isPending)
  #expect(!attempt.finish(.failure(RuntimeError(.unavailable, "Late callback"))))
}

@Test @MainActor func pendingGuestConnectionCanBeCancelled() async throws {
  let attempt = GuestConnectionAttempt()
  var requested = false
  let task = Task { try await attempt.wait(timeout: .seconds(30)) { _ in requested = true } }
  while !requested { await Task.yield() }
  task.cancel()
  switch await task.result {
  case .failure(let error): #expect(error is CancellationError)
  case .success: Issue.record("Cancelled connection unexpectedly succeeded")
  }
  #expect(!attempt.isPending)
}

@Test func transparentRelayPreservesBinaryAndHalfClose() async throws {
  let (client, host) = try socketPair()
  let (guest, server) = try socketPair()
  client.timeout(seconds: 3)
  server.timeout(seconds: 3)
  let relay = Task { await SocketRelay.relay(host, guest) }
  try await Task.detached {
    let binary = Data([0, 255, 128, 10, 13, 0, 42])
    try client.write(binary)
    client.shutdownWrite()
    var received = Data()
    while true {
      let chunk = try server.read()
      if chunk.isEmpty { break }
      received.append(chunk)
    }
    #expect(received == binary)
    try server.write(Data("response-after-client-half-close".utf8))
    server.shutdownWrite()
    var reply = Data()
    while true {
      let chunk = try client.read()
      if chunk.isEmpty { break }
      reply.append(chunk)
    }
    #expect(reply == Data("response-after-client-half-close".utf8))
  }.value
  await relay.value
}
