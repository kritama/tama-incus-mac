import Darwin
import Foundation
import Virtualization
import os

@MainActor
public final class VirtualMachineController: NSObject, VirtualMachineDriver,
  @MainActor VZVirtualMachineDelegate
{
  private var machine: VZVirtualMachine?
  private var activity: (any NSObjectProtocol)?
  private var connections: [UUID: VZVirtioSocketConnection] = [:]
  private let logger = Logger(subsystem: "com.kritama.macus", category: "virtualization")
  public override init() { super.init() }
  public func capabilities() async -> HostCapabilities { CapabilityDetector.detect() }
  public func start(configuration: RuntimeConfiguration, paths: RuntimePaths) async throws {
    guard machine == nil || machine?.state == .stopped || machine?.state == .error else {
      throw RuntimeError(.conflict, "VM already active")
    }
    // Release stopped VZ attachments before reopening EFI and disk files.
    closeConnections()
    machine = nil
    let vm = VZVirtualMachine(
      configuration: try VirtualMachineConfiguration.make(configuration, paths: paths))
    vm.delegate = self
    machine = vm
    endActivity()
    activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "Run user-requested Incus host VM")
    do { try await vm.start() } catch {
      endActivity()
      throw error
    }
  }
  public func requestStop() async throws {
    guard let machine, machine.canRequestStop else {
      throw RuntimeError(.unavailable, "Guest cannot accept graceful shutdown")
    }
    try machine.requestStop()
  }
  public func forceStop() async throws {
    for connection in connections.values {
      _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
    }
    connections.removeAll()
    guard let machine, machine.canStop else { return }
    try await machine.stop()
    self.machine = nil
    endActivity()
  }
  public func isRunning() async -> Bool {
    guard let machine else { return false }
    return machine.state != .stopped && machine.state != .error
  }
  public func openStream(port: UInt32) async throws -> GuestStream {
    guard let device = machine?.socketDevices.first as? VZVirtioSocketDevice,
      machine?.state == .running
    else {
      throw RuntimeError(.unavailable, "Guest socket device is unavailable")
    }
    let attempt = GuestConnectionAttempt()
    return try await attempt.wait { [self] attempt in
      device.connect(toPort: port) { [self] result in
        // VZ invokes this completion on the VM's queue, which is the main queue.
        MainActor.assumeIsolated {
          guard attempt.isPending else {
            // VZ has no cancel-connect API. Discard a connection delivered after
            // our deadline/cancellation instead of retaining or exposing it.
            if case .success(let connection) = result {
              _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
            }
            return
          }
          do {
            let connection = try result.get()
            let descriptor = try SocketDescriptor(dup(connection.fileDescriptor))
            let id = UUID()
            self.connections[id] = connection
            let stream = GuestStream(socket: descriptor) { [weak self] in
              await self?.releaseConnection(id)
            }
            attempt.finish(.success(stream))
          } catch {
            if case .success(let connection) = result {
              _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
            }
            attempt.finish(.failure(error))
          }
        }
      }
    }
  }
  private func releaseConnection(_ id: UUID) { connections.removeValue(forKey: id) }
  public func health() async throws -> GuestHealth {
    let stream = try await openStream(port: 8444)
    stream.socket.timeout(seconds: 2)
    do {
      let data = try await SocketIO.run {
        try stream.socket.write(
          Data("GET /health HTTP/1.1\r\nHost: guest\r\nConnection: close\r\n\r\n".utf8))
        var result = Data()
        while true {
          let chunk = try stream.socket.read()
          if chunk.isEmpty { break }
          result.append(chunk)
          guard result.count < 1_048_576 else {
            throw RuntimeError(.unavailable, "Guest health response too large")
          }
        }
        return result
      }
      stream.socket.shutdown()
      await stream.release()
      guard let split = data.range(of: Data("\r\n\r\n".utf8)),
        String(data: data.prefix(split.lowerBound), encoding: .utf8)?.hasPrefix("HTTP/1.1 200 ")
          == true
      else {
        throw RuntimeError(.unavailable, "Incus helper is not healthy")
      }
      return try JSON.decoder().decode(GuestHealth.self, from: data.suffix(from: split.upperBound))
    } catch {
      stream.socket.shutdown()
      await stream.release()
      throw error
    }
  }
  public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    guard machine === virtualMachine else { return }
    closeConnections()
    machine = nil
    logger.info("Guest stopped")
  }
  public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    guard machine === virtualMachine else { return }
    closeConnections()
    machine = nil
    logger.error("Guest failed: \(error.localizedDescription, privacy: .public)")
  }
  private func endActivity() {
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
  }
  private func closeConnections() {
    endActivity()
    for connection in connections.values {
      _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
    }
    connections.removeAll()
  }
}
