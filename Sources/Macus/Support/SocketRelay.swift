import Darwin
import Foundation

public enum SocketRelay {
  public static func relay(_ first: SocketDescriptor, _ second: SocketDescriptor) async {
    let relay = NonblockingRelay(first, second)
    await withTaskCancellationHandler {
      await withCheckedContinuation { relay.start($0) }
    } onCancel: {
      relay.cancel()
    }
  }
}

/// Mutable state is confined to queue. Each direction buffers at most 64 KiB;
/// idle sockets consume dispatch sources rather than blocking worker threads.
private final class NonblockingRelay: @unchecked Sendable {
  let queue = DispatchQueue(label: "com.upmaru.macus.relay")
  let first: SocketDescriptor
  let second: SocketDescriptor
  var directions: [RelayDirection] = []
  var continuation: CheckedContinuation<Void, Never>?
  var finished = false
  var endedDirections = 0

  init(_ first: SocketDescriptor, _ second: SocketDescriptor) {
    self.first = first
    self.second = second
  }
  func start(_ continuation: CheckedContinuation<Void, Never>) {
    queue.async {
      guard !self.finished else {
        continuation.resume()
        return
      }
      self.continuation = continuation
      do {
        try self.first.setNonblocking()
        try self.second.setNonblocking()
        self.directions = [(self.first, self.second), (self.second, self.first)].map {
          RelayDirection(input: $0.0, output: $0.1, owner: self)
        }
        for direction in self.directions { direction.start() }
      } catch { self.finish() }
    }
  }
  func cancel() { queue.async { self.finish() } }
  func directionEnded() {
    endedDirections += 1
    if endedDirections == 2 { finish() }
  }
  func finish() {
    guard !finished else { return }
    finished = true
    for direction in directions { direction.stop() }
    first.shutdown()
    second.shutdown()
    continuation?.resume()
    continuation = nil
  }
}

/// All fields and callbacks use the owner's serial queue. Cancellation handlers
/// retain FD owners until Dispatch has stopped accessing those descriptors.
private final class RelayDirection: @unchecked Sendable {
  let input: SocketDescriptor
  let output: SocketDescriptor
  weak var owner: NonblockingRelay?
  let reader: any DispatchSourceRead
  let writer: any DispatchSourceWrite
  var readSuspended = false
  var writeSuspended = true
  var stopped = false
  var buffer = Data()
  var offset = 0

  init(input: SocketDescriptor, output: SocketDescriptor, owner: NonblockingRelay) {
    self.input = input
    self.output = output
    self.owner = owner
    reader = DispatchSource.makeReadSource(fileDescriptor: input.rawValue, queue: owner.queue)
    writer = DispatchSource.makeWriteSource(fileDescriptor: output.rawValue, queue: owner.queue)
    reader.setEventHandler { [weak self] in self?.read() }
    writer.setEventHandler { [weak self] in self?.flush() }
    reader.setCancelHandler { withExtendedLifetime(input) {} }
    writer.setCancelHandler { withExtendedLifetime(output) {} }
  }
  func start() { reader.resume() }
  func read() {
    guard !stopped, buffer.isEmpty else { return }
    var bytes = [UInt8](repeating: 0, count: 65536)
    let count = Darwin.read(input.rawValue, &bytes, bytes.count)
    if count > 0 {
      buffer = Data(bytes.prefix(count))
      reader.suspend()
      readSuspended = true
      flush()
    } else if count == 0 {
      output.shutdownWrite()
      stop()
      owner?.directionEnded()
    } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
      owner?.finish()
    }
  }
  func flush() {
    guard !stopped else { return }
    while offset < buffer.count {
      let count = buffer.withUnsafeBytes {
        Darwin.write(output.rawValue, $0.baseAddress!.advanced(by: offset), $0.count - offset)
      }
      if count > 0 {
        offset += count
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        if writeSuspended {
          writer.resume()
          writeSuspended = false
        }
        return
      }
      owner?.finish()
      return
    }
    buffer.removeAll(keepingCapacity: true)
    offset = 0
    if !writeSuspended {
      writer.suspend()
      writeSuspended = true
    }
    if readSuspended {
      reader.resume()
      readSuspended = false
    }
  }
  func stop() {
    guard !stopped else { return }
    stopped = true
    reader.cancel()
    writer.cancel()
    if readSuspended {
      reader.resume()
      readSuspended = false
    }
    if writeSuspended {
      writer.resume()
      writeSuspended = false
    }
  }
}
