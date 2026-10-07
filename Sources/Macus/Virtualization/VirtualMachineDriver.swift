import Foundation

public struct GuestStream: Sendable {
  public let socket: SocketDescriptor
  public let release: @Sendable () async -> Void
  public init(socket: SocketDescriptor, release: @escaping @Sendable () async -> Void) {
    self.socket = socket
    self.release = release
  }
}

public protocol VirtualMachineDriver: Sendable {
  func capabilities() async -> HostCapabilities
  func start(configuration: RuntimeConfiguration, paths: RuntimePaths) async throws
  func requestStop() async throws
  func forceStop() async throws
  func isRunning() async -> Bool
  func openStream(port: UInt32) async throws -> GuestStream
  func health() async throws -> GuestHealth
}
