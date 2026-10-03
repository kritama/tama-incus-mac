import Foundation
import os

public actor RuntimeService {
  private let driver: any VirtualMachineDriver
  private let store: StateStore
  private var configuration: RuntimeConfiguration?
  private var state: RuntimeState
  private var lastError: String?
  private var guestHealth: GuestHealth?
  private var mutationActive = false
  private var startedAt: Date?
  private let logger = Logger(subsystem: "com.kritama.tama-incus-mac", category: "runtime")

  public init(driver: any VirtualMachineDriver, store: StateStore) throws {
    self.driver = driver
    self.store = store
    configuration = try store.load()
    state = configuration == nil ? .absent : .stopped
  }

  public func status() async -> RuntimeStatus {
    await refresh()
    return snapshot()
  }
  public func capabilities() async -> RuntimeCapabilities {
    await refresh()
    return RuntimeCapabilities(
      host: await driver.capabilities(), health: guestHealth,
      nestingEnabled: configuration?.nestedVirtualization == true)
  }
  public func config() throws -> RuntimeConfiguration {
    guard let configuration else { throw RuntimeError(.notFound, "Runtime has not been created") }
    return configuration
  }
  public func health() async throws -> GuestHealth {
    await refresh()
    guard let guestHealth else {
      throw RuntimeError(.unavailable, lastError ?? "Incus is not ready")
    }
    return guestHealth
  }
  public func create(_ value: RuntimeConfiguration) async throws -> RuntimeStatus {
    try beginMutation()
    defer { mutationActive = false }
    if let configuration {
      guard configuration == value else {
        throw RuntimeError(.conflict, "Runtime exists with a different configuration")
      }
      return snapshot()
    }
    try value.validate()
    let store = self.store
    try await Task.detached { try GuestImageManager.create(configuration: value, store: store) }
      .value
    configuration = value
    state = .stopped
    lastError = nil
    return snapshot()
  }
  public func update(_ value: RuntimeConfiguration) async throws -> RuntimeStatus {
    try beginMutation()
    defer { mutationActive = false }
    let current = try config()
    guard !(await driver.isRunning()) else {
      throw RuntimeError(.conflict, "Configuration requires a stopped VM")
    }
    try value.validate()
    guard value.applianceManifestPath == current.applianceManifestPath,
      value.seedPath == current.seedPath
    else {
      throw RuntimeError(
        .invalidConfiguration, "Appliance replacement requires a future upgrade protocol")
    }
    guard value.dataDiskGib >= current.dataDiskGib else {
      throw RuntimeError(.invalidConfiguration, "Disk shrink is unsupported")
    }
    try store.resizeData(gib: value.dataDiskGib)
    try store.save(value)
    configuration = value
    state = .stopped
    lastError = nil
    return snapshot()
  }
  public func start() async throws -> RuntimeStatus {
    try beginMutation()
    defer { mutationActive = false }
    return try await startLocked()
  }
  public func stop(force: Bool = false) async throws -> RuntimeStatus {
    try beginMutation()
    defer { mutationActive = false }
    return try await stopLocked(force: force)
  }
  public func restart() async throws -> RuntimeStatus {
    try beginMutation()
    defer { mutationActive = false }
    _ = try await stopLocked(force: false)
    return try await startLocked()
  }
  public func delete(confirm: Bool) async throws -> RuntimeStatus {
    try beginMutation()
    defer { mutationActive = false }
    guard confirm else { throw RuntimeError(.invalidRequest, "Deletion requires confirm=true") }
    guard !(await driver.isRunning()) else {
      throw RuntimeError(.conflict, "Stop the VM before deleting runtime data")
    }
    try store.delete()
    configuration = nil
    state = .absent
    guestHealth = nil
    lastError = nil
    startedAt = nil
    return snapshot()
  }
  public func openIncusStream() async throws -> GuestStream {
    guard state == .ready else { throw RuntimeError(.unavailable, "Incus is not ready") }
    return try await driver.openStream(port: 8443)
  }

  private func beginMutation() throws {
    guard !mutationActive else {
      throw RuntimeError(.conflict, "A runtime mutation is already in progress")
    }
    mutationActive = true
  }
  private func startLocked() async throws -> RuntimeStatus {
    let value = try config()
    await refresh()
    if state == .ready { return snapshot() }
    guard !(await driver.isRunning()) else {
      throw RuntimeError(.conflict, "VM is running but unhealthy; stop before recovery")
    }
    guard (await driver.capabilities()).supported else {
      throw RuntimeError(.unavailable, "Apple virtualization is unavailable on this host")
    }
    state = .starting
    lastError = nil
    guestHealth = nil
    logger.info("Starting outer Linux VM")
    do {
      try await driver.start(configuration: value, paths: store.paths)
      startedAt = Date()
      let deadline = ContinuousClock.now.advanced(by: .seconds(value.readinessTimeoutSeconds))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        guard await driver.isRunning() else {
          throw RuntimeError(
            .unavailable, "Guest exited before Incus became ready; inspect serial.log")
        }
        if let health = try? await driver.health(), health.protocolVersion == 1 {
          guestHealth = health
          state = .ready
          logger.info("Incus ready: \(health.incusVersion, privacy: .public)")
          return snapshot()
        }
        try await Task.sleep(for: .milliseconds(500))
      }
      throw RuntimeError(
        .timeout, "Incus readiness timed out; inspect serial.log, then stop/start to recover")
    } catch {
      state = .failed
      lastError = error.localizedDescription
      guestHealth = nil
      throw error
    }
  }
  private func stopLocked(force: Bool) async throws -> RuntimeStatus {
    let value = try config()
    guestHealth = nil
    if !(await driver.isRunning()) {
      state = .stopped
      startedAt = nil
      return snapshot()
    }
    state = .stopping
    do {
      if force {
        try await driver.forceStop()
      } else {
        try await driver.requestStop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(value.shutdownTimeoutSeconds))
        while await driver.isRunning() {
          guard ContinuousClock.now < deadline else {
            throw RuntimeError(
              .timeout, "Graceful shutdown timed out; explicitly force stop if required")
          }
          try await Task.sleep(for: .milliseconds(100))
        }
      }
      state = .stopped
      startedAt = nil
      lastError = nil
      return snapshot()
    } catch {
      state = .failed
      lastError = error.localizedDescription
      throw error
    }
  }
  private func refresh() async {
    guard state == .ready, !mutationActive else { return }
    if !(await driver.isRunning()) {
      state = .failed
      lastError = "Guest exited unexpectedly"
      guestHealth = nil
      startedAt = nil
    } else if let live = try? await driver.health(), live.protocolVersion == 1 {
      guestHealth = live
    } else {
      state = .failed
      guestHealth = nil
      lastError = "Guest health unavailable; stop/start to recover"
    }
  }
  private func snapshot() -> RuntimeStatus {
    RuntimeStatus(
      state: state, incusSocket: store.paths.incusSocket.path, lastError: lastError,
      uptimeSeconds: startedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0)
  }
}
