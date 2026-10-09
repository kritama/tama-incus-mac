import Darwin
import Foundation
import Noora

/// Component callbacks, the stage ledger, cursor ownership and real stream writes share one lock.
final class TerminalProgressSink: StartupProgressSink, @unchecked Sendable {
  private let lock = NSLock()
  private var rendering: ProgressRendering
  private var ledger = ProgressLedger()
  private var events: [StartupStage: StartupProgressEvent] = [:]
  private var received: [StartupStage: ContinuousClock.Instant] = [:]
  private var order: [StartupStage] = []
  private var workers: [StartupStage: NativeStageWorker] = [:]
  private var frames: [StartupStage: String] = [:]
  private var printed: Set<StartupStage> = []
  private var resolutionOrder: [StartupStage] = []
  private var completions: [StartupStage: String] = [:]
  private var messages: [StartupStage: String] = [:]
  private var lastDraw: ContinuousClock.Instant?
  private var promptRedraw: Set<StartupStage> = []
  private var lastUpdate: [StartupStage: ContinuousClock.Instant] = [:]
  private var signatures: [StartupStage: String] = [:]
  private var measuredBar: (key: String, text: String)?
  private var refresh: Task<Void, Never>?
  private var finishing: Task<Void, Never>?
  private var accepting = true
  private var closed = false
  private var cursorHidden = false
  private var liveLine = false
  private var animation = 0
  private let write: @Sendable (String) -> Void
  private let width: @Sendable () -> Int?
  private let environment: [String: String]
  private let isTTY: Bool
  private let now: @Sendable () -> ContinuousClock.Instant

  init(
    rendering: ProgressRendering, environment: [String: String] = [:],
    stderrIsTTY: Bool? = nil, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    width: @escaping @Sendable () -> Int? = {
      var size = winsize()
      guard ioctl(STDERR_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return nil }
      return Int(size.ws_col)
    }, write: @escaping @Sendable (String) -> Void
  ) {
    self.rendering = rendering
    self.width = width
    self.write = write
    self.environment = environment
    self.now = now
    isTTY = stderrIsTTY ?? (rendering == .animated || isatty(STDERR_FILENO) == 1)
  }

  func startRefreshing() {
    lock.lock()
    defer { lock.unlock() }
    guard refresh == nil, accepting, rendering != .none else { return }
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
    guard accepting, rendering != .none, ledger.observe(event) else { return }
    events[event.stage] = event
    received[event.stage] = now()
    if event.state == .active {
      order.removeAll { $0 == event.stage }
      order.append(event.stage)
    }
    guard event.state != .pending else { return }
    if workers[event.stage] == nil {
      let interactive = rendering == .animated && (width() ?? 0) >= 40
      let terminal = MacusTerminal(
        descriptor: STDERR_FILENO, isTTY: interactive, environment: environment,
        width: width, write: { _ in })
      let stage = event.stage
      workers[stage] = NativeStageWorker(
        event: event, terminal: terminal,
        receive: { [weak self] text in self?.receive(text, stage: stage) })
    }
    if event.state == .active {
      update(event, now: now())
    } else {
      resolutionOrder.append(event.stage)
      workers[event.stage]?.resolve(event.state)
    }
  }

  func diagnostic(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    guard accepting, rendering != .none else { return }
    clearLine()
    for line in text.split(separator: "\n") { output("  " + terminalSafe(String(line)) + "\n") }
  }

  private var activeStage: StartupStage? { order.last { ledger.stages[$0] == .active } }

  private func update(_ event: StartupProgressEvent, now: ContinuousClock.Instant) {
    let signature = "\(event.detail ?? "")|\(event.expectedReboot)"
    let changed = signatures[event.stage] != signature
    let interval: Duration = rendering == .plain ? .seconds(5) : .milliseconds(100)
    if !changed, let previous = lastUpdate[event.stage], now < previous.advanced(by: interval) {
      return
    }
    let text = message(event)
    guard text != messages[event.stage] else { return }
    signatures[event.stage] = signature
    messages[event.stage] = text
    lastUpdate[event.stage] = now
    if changed { promptRedraw.insert(event.stage) }
    workers[event.stage]?.update(text)
  }

  private func message(_ event: StartupProgressEvent) -> String {
    let label = event.expectedReboot ? "Waiting for expected kernel reboot" : event.stage.label
    var text = label
    let size = width() ?? 0
    if let bytes = byteProgress(event) {
      let key = "\(event.completedBytes ?? 0)/\(event.totalBytes ?? 0)"
      if rendering == .animated, let bar = measuredBar, bar.key == key,
        displayWidth(label + " " + bar.text + " | " + ledger.count) <= size - 4
      {
        text += " " + bar.text
      } else {
        text += " " + bytes
      }
    }
    text += " (\(humanDuration(event.elapsedSeconds)))"
    if let detail = event.detail, !detail.isEmpty { text += " | " + readableDetail(detail) }
    if rendering == .animated {
      let context = ledger.bar + " " + ledger.count
      if displayWidth(text + " | " + context) <= size - 4 {
        text += " | " + context
      } else if displayWidth(label + " | " + ledger.count) <= size - 4 {
        text = label + " | " + ledger.count
      }
    }
    return text
  }

  private func receive(_ content: String, stage: StartupStage) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    var text = content.trimmingCharacters(in: .newlines)
    let plain = withoutStyling(text).trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = plain.hasPrefix("✔︎") || plain.hasPrefix("⨯")
    if resolved {
      // A stage may begin before discovering reusable state. Preserve Noora's marker/time/style.
      if ledger.stages[stage] == .skipped {
        text = text.replacingOccurrences(of: stage.successLabel, with: stage.skippedLabel)
      }
      completions[stage] = text
      flushCompleted()
    } else {
      if rendering == .plain {
        output(withoutStyling(text) + "\n")
      } else {
        guard accepting, ledger.stages[stage] == .active else { return }
        frames[stage] = text
        if activeStage == stage { drawActive(force: promptRedraw.remove(stage) != nil) }
      }
    }
  }

  private func flushCompleted() {
    while let stage = resolutionOrder.first, let text = completions.removeValue(forKey: stage) {
      resolutionOrder.removeFirst()
      guard printed.insert(stage).inserted else { continue }
      clearLine()
      if rendering == .animated, (width() ?? 0) < 40 {
        showCursor()
        rendering = .plain
      }
      let line =
        rendering == .animated
        ? fitNativeCompletion(text, width: max(1, (width() ?? 80) - 2)) : withoutStyling(text)
      output(line + "\n")
    }
    drawActive(force: true)
  }

  private func drawActive(force: Bool = false) {
    guard accepting, rendering == .animated, let stage = activeStage, let frame = frames[stage]
    else { return }
    guard let size = width(), size >= 40 else {
      clearLine()
      showCursor()
      rendering = .plain
      output(withoutStyling(frame) + "\n")
      return
    }
    if !force, liveLine, let lastDraw, now() < lastDraw.advanced(by: .milliseconds(100)) { return }
    lastDraw = now()
    var line = frame
    if let icon = line.range(of: "ℹ︎") {
      let icons = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
      line.replaceSubrange(icon, with: icons[animation % icons.count])
    }
    if !cursorHidden {
      output("\u{1B}[?25l")
      cursorHidden = true
    }
    output("\r\u{1B}[2K" + fitStyledLine(line, width: size - 2))
    liveLine = true
  }

  private func output(_ text: String) { write(terminalLineBoundaries(text, isTTY: isTTY)) }
  private func clearLine() {
    if liveLine {
      output("\r\u{1B}[2K")
      liveLine = false
    }
  }
  private func showCursor() {
    if cursorHidden {
      output("\u{1B}[?25h")
      cursorHidden = false
    }
  }

  private func snapshot() -> (StartupProgressEvent, ContinuousClock.Instant)? {
    lock.lock()
    defer { lock.unlock() }
    guard accepting, let stage = activeStage, let event = events[stage], let time = received[stage]
    else { return nil }
    return (event, time)
  }
  private func tick() async {
    guard let (observation, time) = snapshot() else { return }
    var event = observation
    event.elapsedSeconds += max(0, Int(time.duration(to: now()).components.seconds))
    if event.stage == .acquisition, let total = event.totalBytes, total > 0,
      let completed = event.completedBytes
    {
      let key = "\(completed)/\(total)"
      if needsBar(key) {
        let fraction = Double(min(max(0, completed), total)) / Double(total)
        let frame = await NooraMeasuredBar.frame(
          message: "\(humanBytes(completed)) / \(humanBytes(total))", fraction: fraction)
        acceptBar(frame, key: key, event: observation)
      }
    }
    refreshFrame(event, time: time)
  }
  private func refreshFrame(_ event: StartupProgressEvent, time: ContinuousClock.Instant) {
    lock.lock()
    defer { lock.unlock() }
    guard accepting, received[event.stage] == time, ledger.stages[event.stage] == .active else {
      return
    }
    animation += 1
    update(event, now: now())
    drawActive()
  }
  private func needsBar(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return accepting && measuredBar?.key != key
  }
  private func acceptBar(_ text: String?, key: String, event: StartupProgressEvent) {
    lock.lock()
    defer { lock.unlock() }
    guard accepting, events[event.stage] == event, let text else { return }
    measuredBar = (key, text.hasPrefix("ℹ︎ ") ? String(text.dropFirst("ℹ︎ ".count)) : text)
  }

  private func finishTask(ready: Bool, connected: Bool) -> Task<Void, Never> {
    lock.lock()
    defer { lock.unlock() }
    if let finishing { return finishing }
    accepting = false
    let refresh = self.refresh
    self.refresh = nil
    refresh?.cancel()
    let workers = Array(self.workers.values)
    for stage in order where ledger.stages[stage] == .active && !resolutionOrder.contains(stage) {
      resolutionOrder.append(stage)
    }
    for worker in workers { worker.end() }
    let task = Task { [weak self] in
      await refresh?.value
      for worker in workers { await worker.task.value }
      self?.close(ready: ready, connected: connected)
    }
    finishing = task
    return task
  }
  func finish(ready: Bool = false, connected: Bool = false) async {
    await finishTask(ready: ready, connected: connected).value
  }
  private func close(ready: Bool, connected: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closed = true
    clearLine()
    showCursor()
    ledger.confirm(ready: ready, connected: connected)
    if rendering != .none, ready && connected { output("Startup: \(ledger.count) resolved\n") }
  }
  func cleanup() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    accepting = false
    closed = true
    refresh?.cancel()
    refresh = nil
    for worker in workers.values { worker.end() }
    clearLine()
    showCursor()
  }
}

private enum NativeStepAction: Sendable {
  case update(String)
  case resolve(StartupStageState)
}
private struct NativeStageFailure: Error {}
private struct NativeStageWorker: Sendable {
  let continuation: AsyncStream<NativeStepAction>.Continuation
  let task: Task<Void, Never>
  init(
    event: StartupProgressEvent, terminal: MacusTerminal,
    receive: @escaping @Sendable (String) -> Void
  ) {
    let (stream, continuation) = AsyncStream<NativeStepAction>.makeStream()
    self.continuation = continuation
    let skipped = event.state == .skipped
    let message = skipped ? event.stage.skippedLabel : event.stage.label
    let success = skipped ? event.stage.skippedLabel : event.stage.successLabel
    let renderer = NativeStepRenderer()
    let pipeline = StreamPipeline(write: receive)
    task = Task {
      let noora = Noora(
        terminal: terminal, standardPipelines: StandardPipelines(output: pipeline, error: pipeline))
      do {
        try await noora.progressStep(
          message: message, successMessage: success,
          errorMessage: event.stage.label + " failed", showSpinner: false, renderer: renderer
        ) { update in
          for await action in stream {
            switch action {
            case .update(let message): update(message)
            case .resolve(let state):
              if state == .failed { throw NativeStageFailure() }
              return
            }
          }
          throw NativeStageFailure()
        }
      } catch {
        // Noora has emitted the native failure row through the serialized sink.
      }
    }
  }
  func update(_ text: String) { continuation.yield(.update(text)) }
  func resolve(_ state: StartupStageState) {
    continuation.yield(.resolve(state))
    continuation.finish()
  }
  func end() { continuation.finish() }
}
private final class NativeStepRenderer: Rendering, Sendable {
  func render(_ input: String, standardPipeline: any StandardPipelining) {
    standardPipeline.write(content: input)
  }
}

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
