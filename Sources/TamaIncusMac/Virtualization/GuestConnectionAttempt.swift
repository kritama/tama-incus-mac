import Foundation

/// Bounds a callback connection attempt without waiting for an unresponsive guest.
@MainActor
final class GuestConnectionAttempt {
  private var continuation: CheckedContinuation<GuestStream, any Error>?
  private var deadline: Task<Void, Never>?
  private(set) var isPending = true

  func wait(
    timeout: Duration = .seconds(2), connect: (GuestConnectionAttempt) -> Void
  ) async throws -> GuestStream {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        if Task.isCancelled {
          finish(.failure(CancellationError()))
          return
        }
        deadline = Task {
          do { try await Task.sleep(for: timeout) } catch { return }
          finish(.failure(RuntimeError(.timeout, "Guest vsock connection timed out")))
        }
        connect(self)
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }

  @discardableResult
  func finish(_ result: Result<GuestStream, any Error>) -> Bool {
    guard isPending, let continuation else { return false }
    isPending = false
    deadline?.cancel()
    deadline = nil
    self.continuation = nil
    continuation.resume(with: result)
    return true
  }
}
