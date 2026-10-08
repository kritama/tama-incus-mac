import Darwin
import Foundation
import Noora

/// Renderer state and actual Noora pipeline writes share this lock. Async refresh owns no signals.
final class TerminalProgressSink: StartupProgressSink, @unchecked Sendable {
  private let lock = NSLock()
  private var renderer: ProgressRenderer
  private var closed = false
  private var latest: StartupProgressEvent?
  private var received: ContinuousClock.Instant = .now
  private var refresh: Task<Void, Never>?
  private let presentation: HumanPresentation
  private let width: @Sendable () -> Int?
  private var componentBar: String?
  private var componentKey: String?

  init(
    rendering: ProgressRendering, environment: [String: String] = [:],
    width: @escaping @Sendable () -> Int? = {
      var size = winsize()
      guard ioctl(STDERR_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return nil }
      return Int(size.ws_col)
    }, write: @escaping @Sendable (String) -> Void
  ) {
    renderer = ProgressRenderer(rendering: rendering)
    self.width = width
    var streams = MacusStreams(writeOutput: write, writeError: write)
    streams.stderrIsTTY = rendering == .animated
    presentation = HumanPresentation(streams: streams, environment: environment, error: true)
  }

  func startRefreshing() {
    lock.lock()
    defer { lock.unlock() }
    guard refresh == nil, !closed, renderer.rendering != .none else { return }
    refresh = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        guard let self else { break }
        await self.tick()
      }
    }
  }

  func emit(_ event: StartupProgressEvent) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    if latest?.stage != event.stage || latest?.completedBytes != event.completedBytes
      || latest?.totalBytes != event.totalBytes
    {
      componentBar = nil
      componentKey = nil
    }
    latest = event
    received = .now
    render(event, now: .now)
  }

  func diagnostic(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, renderer.rendering != .none else { return }
    presentation.text(renderer.pauseLine())
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
      presentation.text("  " + terminalSafe(String(line)) + "\n")
    }
  }

  private func render(_ event: StartupProgressEvent, now: ContinuousClock.Instant) {
    if let text = renderer.render(event, now: now, width: width(), measuredBar: componentBar) {
      // Constructed cursor controls are trusted; every external detail was escaped by the renderer.
      presentation.noora.passthrough("\(.primary(text))", pipeline: .error)
    }
  }

  private func snapshot() -> (StartupProgressEvent, ContinuousClock.Instant)? {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, let latest else { return nil }
    return (latest, received)
  }

  private func tick() async {
    guard let (observation, timestamp) = snapshot(), observation.state == .active else { return }
    var event = observation
    event.elapsedSeconds += max(0, Int(timestamp.duration(to: .now).components.seconds))
    if event.stage == .acquisition, let total = event.totalBytes, total > 0,
      let completed = event.completedBytes
    {
      let fraction = Double(min(max(0, completed), total)) / Double(total)
      let key = "\(completed)/\(total)"
      if needsComponent(key) {
        let message = "\(humanBytes(completed)) / \(humanBytes(total))"
        let bar = await NooraMeasuredBar.frame(message: message, fraction: fraction)
        acceptComponent(bar, key: key, event: event)
      }
    }
    refreshEvent(event, timestamp: timestamp)
  }
  private func needsComponent(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !closed && componentKey != key
  }
  private func acceptComponent(_ frame: String?, key: String, event: StartupProgressEvent) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, latest?.stage == event.stage,
      latest?.completedBytes == event.completedBytes, latest?.totalBytes == event.totalBytes
    else { return }
    componentBar = frame
    componentKey = key
  }
  private func refreshEvent(_ event: StartupProgressEvent, timestamp: ContinuousClock.Instant) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, received == timestamp else { return }
    render(event, now: .now)
  }

  /// Closing first prevents late events, including a component callback already in flight.
  private func close(ready: Bool, connected: Bool) -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return nil }
    closed = true
    let task = refresh
    refresh = nil
    task?.cancel()
    let final = renderer.confirm(ready: ready, connected: connected) + renderer.cleanup()
    presentation.text(final)
    return task
  }
  func finish(ready: Bool = false, connected: Bool = false) async {
    let task = close(ready: ready, connected: connected)
    await task?.value
  }
  func cleanup() { _ = close(ready: false, connected: false) }
}

/// Use Noora's measured component without its unsynchronized spinner or terminal ownership.
/// Capture its fixed 30-cell bar, then compose it with the ledger inside our serialized renderer.
private enum NooraMeasuredBar {
  static func frame(message: String, fraction: Double) async -> String? {
    let capture = BarCapture()
    let terminal = MacusTerminal(
      descriptor: STDERR_FILENO, isTTY: false, environment: [:], write: { _ in })
    let pipeline = StreamPipeline { capture.write($0) }
    let noora = Noora(
      terminal: terminal, standardPipelines: StandardPipelines(output: pipeline, error: pipeline))
    _ = try? await noora.progressBarStep(message: message) { update in update(fraction) }
    return capture.frame
  }
}
private final class BarCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?
  func write(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    if value.contains("▒") || value.contains("█") {
      stored = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
  var frame: String? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
