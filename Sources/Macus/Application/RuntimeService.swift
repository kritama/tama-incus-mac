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
  private var generation: UInt64 = 0
  private var startingTask: Task<RuntimeStatus, Error>?
  private var startedAt: Date?
  private let logger = Logger(subsystem: "com.upmaru.macus", category: "runtime")
  private var bootPhase: String?
  private var bootExpectedReboot = false
  private var bootStartedAt: ContinuousClock.Instant?

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
    try RebootAllowanceStore.ensureAvailable(
      paths: store.paths, catalogID: value.applianceManifestPath)
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
    try await start(remainingSeconds: nil)
  }
  public func start(remainingSeconds: Int?) async throws -> RuntimeStatus {
    if let remainingSeconds, !(1...3_600).contains(remainingSeconds) {
      throw RuntimeError(.invalidRequest, "remaining_seconds must be an integer from 1 to 3600")
    }
    try beginMutation()
    let operationGeneration = generation
    defer { if generation == operationGeneration { mutationActive = false } }
    return try await boot(
      remainingSeconds: remainingSeconds, operationGeneration: operationGeneration)
  }
  public func progress() -> RuntimeProgress {
    let elapsed: Int
    if let bootStartedAt {
      elapsed = max(0, Int(bootStartedAt.duration(to: .now).components.seconds))
    } else {
      elapsed = startedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
    }
    return RuntimeProgress(
      apiVersion: 1, schemaVersion: 1, state: state, ready: state == .ready && guestHealth != nil,
      operation: state == .starting || mutationActive ? "start" : nil, phase: bootPhase,
      elapsedSeconds: elapsed, expectedReboot: bootExpectedReboot, detail: nil, lastError: lastError
    )
  }
  public func stop(force: Bool = false) async throws -> RuntimeStatus {
    if force, mutationActive, state == .starting, let startingTask {
      // Emergency stop owns the mutation gate after cancelling the boot task.
      generation &+= 1
      state = .stopping
      startingTask.cancel()
      _ = try? await startingTask.value
      defer { mutationActive = false }
      return try await stopLocked(force: true)
    }
    try beginMutation()
    defer { mutationActive = false }
    return try await stopLocked(force: force)
  }
  public func restart() async throws -> RuntimeStatus {
    try beginMutation()
    let operationGeneration = generation
    defer { if generation == operationGeneration { mutationActive = false } }
    _ = try await stopLocked(force: false)
    return try await boot(remainingSeconds: nil, operationGeneration: operationGeneration)
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
    generation &+= 1
    mutationActive = true
  }
  private func boot(remainingSeconds: Int?, operationGeneration: UInt64) async throws
    -> RuntimeStatus
  {
    let task = Task {
      try await self.startLocked(
        remainingSeconds: remainingSeconds, operationGeneration: operationGeneration)
    }
    startingTask = task
    defer { startingTask = nil }
    return try await task.value
  }
  private func startLocked(remainingSeconds: Int?, operationGeneration: UInt64) async throws
    -> RuntimeStatus
  {
    let value = try config()
    // This operation owns the mutation gate, so refresh() intentionally cannot run here.
    if state == .ready {
      if await driver.isRunning() {
        if let live = try? await driver.health(), live.protocolVersion == 1 {
          try Task.checkCancellation()
          guestHealth = live
          return snapshot()
        }
        state = .failed
        guestHealth = nil
        lastError = "Guest health unavailable; stop/start to recover"
      } else {
        state = .failed
        guestHealth = nil
        startedAt = nil
        lastError = "Guest exited unexpectedly"
      }
    }
    guard !(await driver.isRunning()) else {
      throw RuntimeError(.conflict, "VM is running but unhealthy; stop before recovery")
    }
    guard (await driver.capabilities()).supported else {
      throw RuntimeError(.unavailable, "Apple virtualization is unavailable on this host")
    }
    let limit =
      remainingSeconds.map { min($0, value.readinessTimeoutSeconds) }
      ?? value.readinessTimeoutSeconds
    let deadline = ContinuousClock.now.advanced(by: .seconds(limit))
    state = .starting
    lastError = nil
    guestHealth = nil
    bootPhase = "booting"
    bootExpectedReboot = false
    bootStartedAt = .now
    logger.info("Starting outer Linux VM")
    do {
      var restarted = false
      var sawReboot = false
      var offset = try GuestObservationParser.endOffset(store.paths.serialLog)
      try Task.checkCancellation()
      try await driver.start(configuration: value, paths: store.paths)
      startedAt = Date()
      while true {
        guard ContinuousClock.now < deadline else {
          throw RuntimeError(
            .timeout, "Incus readiness timed out; inspect serial.log, then stop/start to recover")
        }
        try Task.checkCancellation()
        guard generation == operationGeneration, state == .starting else {
          throw CancellationError()
        }
        let read = try GuestObservationParser.read(url: store.paths.serialLog, from: offset)
        offset = read.offset
        if let phase = read.observations.last?.stage { bootPhase = phase }
        if read.observations.contains(where: { $0.expectsKernelReboot }) {
          sawReboot = true
          bootExpectedReboot = true
        }
        if !(await driver.isRunning()) {
          let again = try GuestObservationParser.read(url: store.paths.serialLog, from: offset)
          offset = again.offset
          if again.observations.contains(where: { $0.expectsKernelReboot }) {
            sawReboot = true
            bootExpectedReboot = true
          }
          if sawReboot && !restarted {
            try RebootAllowanceStore.consume(paths: store.paths)
            try Task.checkCancellation()
            guard generation == operationGeneration, state == .starting else {
              throw CancellationError()
            }
            guard ContinuousClock.now < deadline else {
              throw RuntimeError(
                .timeout, "Incus readiness timed out before the expected kernel restart")
            }
            restarted = true
            sawReboot = false
            bootPhase = "expected_reboot"
            offset = try GuestObservationParser.endOffset(store.paths.serialLog)
            try await driver.start(configuration: value, paths: store.paths)
            startedAt = Date()
            continue
          }
          if sawReboot && restarted {
            throw RuntimeError(
              .unavailable,
              "The guest requested another kernel restart after the fresh-bootstrap allowance was consumed. The runtime was not deleted."
            )
          }
          throw RuntimeError(
            .unavailable, "Guest exited before Incus became ready; inspect serial.log")
        }
        if let health = try? await driver.health(), health.protocolVersion == 1 {
          try Task.checkCancellation()
          guard generation == operationGeneration else { throw CancellationError() }
          guestHealth = health
          state = .ready
          bootPhase = "ready"
          logger.info("Incus ready: \(health.incusVersion, privacy: .public)")
          return snapshot()
        }
        try await Task.sleep(for: .milliseconds(500))
      }
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
    let observedGeneration = generation
    let running = await driver.isRunning()
    guard state == .ready, !mutationActive, generation == observedGeneration else { return }
    if !running {
      state = .failed
      lastError = "Guest exited unexpectedly"
      guestHealth = nil
      startedAt = nil
    } else {
      let live = try? await driver.health()
      guard state == .ready, !mutationActive, generation == observedGeneration else { return }
      if let live, live.protocolVersion == 1 {
        guestHealth = live
      } else {
        state = .failed
        guestHealth = nil
        lastError = "Guest health unavailable; stop/start to recover"
      }
    }
  }
  private func snapshot() -> RuntimeStatus {
    RuntimeStatus(
      state: state, incusSocket: store.paths.incusSocket.path, lastError: lastError,
      uptimeSeconds: startedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0)
  }
}
