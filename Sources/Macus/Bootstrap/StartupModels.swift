import Foundation

enum StartupStage: String, Codable, Sendable {
  case preflight
  case acquisition
  case verification
  case preparation
  case serviceActivation = "service_activation"
  case runtimeCreation = "runtime_creation"
  case provisioning
  case readiness
  case clientSetup = "client_setup"
}

enum StartupStageState: String, Codable, Sendable {
  case pending, active, complete, failed, skipped
}

struct StartupProgressEvent: Sendable, Equatable {
  var operationID: String
  var stage: StartupStage
  var state: StartupStageState
  var elapsedSeconds: Int
  var completedBytes: Int64?
  var totalBytes: Int64?
  var detail: String?
  var errorCode: String?
  var expectedReboot: Bool = false

  var hasMeasurableBytes: Bool {
    guard let totalBytes, totalBytes > 0, completedBytes != nil else { return false }
    return true
  }
}

protocol StartupProgressSink: Sendable {
  func emit(_ event: StartupProgressEvent)
  func diagnostic(_ text: String)
}

extension StartupProgressSink {
  func diagnostic(_ text: String) {}
}

final class CollectingProgressSink: StartupProgressSink, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [StartupProgressEvent] = []
  func emit(_ event: StartupProgressEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }
  func snapshot() -> [StartupProgressEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}

/// One monotonic deadline shared by every startup stage. Cancellation does not replace it.
struct StartupBudget: Sendable, Equatable {
  let started: ContinuousClock.Instant
  let deadline: ContinuousClock.Instant

  init(seconds: Int, now: ContinuousClock.Instant) {
    started = now
    deadline = now.advanced(by: .seconds(seconds))
  }

  func remaining(at now: ContinuousClock.Instant) -> Duration {
    guard now < deadline else { return .zero }
    return now.duration(to: deadline)
  }

  func remainingSeconds(at now: ContinuousClock.Instant) throws -> Int {
    guard now < deadline else {
      throw RuntimeError(.timeout, "Startup deadline exceeded")
    }
    let components = now.duration(to: deadline).components
    let seconds = components.seconds + (components.attoseconds > 0 ? 1 : 0)
    guard seconds >= 1 else { throw RuntimeError(.timeout, "Startup deadline exceeded") }
    return Int(min(seconds, 3_600))
  }
}

struct StartupInterrupted: Error, Sendable {
  var message: String
}

struct StartupResult: Sendable {
  var ready: Bool
  var connected: Bool
  var stateDirectory: String
  var remote: String
  var incus: String
  var installed: Bool
  var serviceOwnership: String
  var serviceLabel: String?
  var capabilities: RuntimeCapabilities?
  var nextCommands: [String]
  var pathGuidance: String?
  var observedState: String?
}

enum ProgressSelection: String, Sendable {
  case auto, plain, none
}

struct StartupRequest: Sendable {
  var stateDirectory: URL
  var remote: String
  var setDefault: Bool
  var incusOverride: String?
  var timeout: Int
  var environment: [String: String]
  var operationID: String = UUID().uuidString
}
