import Darwin
import Foundation
import Testing

@testable import Macus

private func observation(
  _ stage: StartupStage = .readiness, _ state: StartupStageState = .active,
  bytes: Int64? = nil, total: Int64? = nil, detail: String? = nil, reboot: Bool = false
) -> StartupProgressEvent {
  StartupProgressEvent(
    operationID: "fixture", stage: stage, state: state,
    elapsedSeconds: 72, completedBytes: bytes, totalBytes: total, detail: detail,
    expectedReboot: reboot)
}

@Test func stageLedgerCountsSkippedAndDuplicateStagesAndGatesSuccess() {
  var ledger = ProgressLedger()
  for stage in [
    StartupStage.preflight, .acquisition, .verification, .preparation,
    .serviceActivation, .runtimeCreation, .provisioning, .readiness, .clientSetup,
  ] {
    let accepted = ledger.observe(observation(stage, .skipped))
    #expect(accepted)
    let repeated = ledger.observe(observation(stage, .skipped))
    #expect(!repeated)
  }
  #expect(ledger.resolvedStages == 8)
  let stale = ledger.observe(observation(.provisioning))
  #expect(!stale)
  #expect(ledger.resolvedStages == 8)
  ledger.confirm(ready: true, connected: false)
  #expect(ledger.resolvedStages == 8)
  ledger.confirm(ready: true, connected: true)
  #expect(ledger.resolvedStages == 9)
  var failed = ProgressLedger()
  let failureAccepted = failed.observe(observation(.readiness, .failed))
  #expect(failureAccepted)
  #expect(failed.resolvedStages == 0)
  let lateSuccess = failed.observe(observation(.readiness, .complete))
  #expect(!lateSuccess)
}

@Test func measuredCountersAreBoundedAndUnknownWaitsRemainActivities() async throws {
  for (bytes, total, expected) in [
    (Int64(-4), Int64(8), "0%"), (4, 8, "50%"), (12, 8, "100%"), (Int64.max, Int64.max, "100%"),
  ] {
    #expect(
      byteProgress(observation(.acquisition, bytes: bytes, total: total))?.contains(expected)
        == true)
  }
  for total: Int64? in [nil, 0, -1] {
    #expect(byteProgress(observation(.acquisition, bytes: 128, total: total)) == "128 bytes")
  }
  let capture = StartCapture()
  let sink = TerminalProgressSink(
    rendering: .plain, stderrIsTTY: false, write: capture.streams.writeError)
  sink.emit(observation(detail: "packages", reboot: true))
  await sink.finish()
  #expect(capture.error.contains("Waiting for expected kernel reboot"))
  #expect(capture.error.contains("1m 12s"))
  #expect(capture.error.contains("Installing guest packages"))
  #expect(!capture.error.contains("%"))
}

@Test func plainProgressThrottlesRepeatedUpdatesAndKeepsTransitions() async {
  let capture = StartCapture()
  let time = ProgressTestClock()
  let sink = TerminalProgressSink(
    rendering: .plain, stderrIsTTY: false, now: { time.value }, write: capture.streams.writeError)
  sink.emit(observation(.acquisition, bytes: 1))
  for step in 1..<50 {
    time.set(.milliseconds(step * 100))
    sink.emit(observation(.acquisition, bytes: Int64(step)))
  }
  time.set(.seconds(5))
  sink.emit(observation(.acquisition, bytes: 80))
  time.set(.milliseconds(5_001))
  sink.emit(observation(.acquisition, bytes: 81, detail: "new detail"))
  sink.emit(observation(.acquisition, .complete))
  await sink.finish()
  let text = withoutStyling(capture.error)
  #expect(text.contains("1 bytes"))
  #expect(!text.contains("49 bytes"))
  #expect(text.contains("80 bytes"))
  #expect(text.contains("new detail"))
  #expect(text.contains("✔︎ Appliance downloaded"))
  #expect(!text.contains("\u{1B}"))
}

@Test func nativeStepsUseNooraOutcomesAndRetainOrderedSkippedScrollback() async throws {
  let capture = StartCapture()
  let sink = TerminalProgressSink(
    rendering: .animated, environment: ["TERM": "xterm", "NO_COLOR": ""], width: { 120 },
    write: capture.streams.writeError)
  sink.startRefreshing()
  sink.emit(observation(.preflight))
  try await Task.sleep(for: .milliseconds(130))
  #expect(capture.error.contains("⠙") || capture.error.contains("⠋"))
  sink.emit(observation(.preflight, .complete))
  sink.emit(observation(.acquisition, .skipped))
  sink.emit(observation(.verification, .skipped))
  sink.emit(observation(.provisioning))
  sink.emit(observation(.provisioning, .skipped))
  await sink.finish()
  let text = withoutStyling(capture.error)
  #expect(text.contains("✔︎ Skipped provisioning (Linux already ready)"))
  #expect(!text.contains("✔︎ Linux provisioned"))
  let host = try #require(text.range(of: "✔︎ Host checked"))
  let download = try #require(text.range(of: "✔︎ Skipped download"))
  let verified = try #require(text.range(of: "✔︎ Skipped verification"))
  #expect(host.lowerBound < download.lowerBound && download.lowerBound < verified.lowerBound)
  #expect(text.contains("[0."))
  #expect(!text.contains("[complete]"))
  #expect(!text.contains("[skipped]"))
  #expect(!text.contains("Appliance downloaded"))
}

@Test func progressFitsStyledUnicodeWidthsAndPreservesCompletionTime() {
  #expect(displayWidth("界😀e\u{301}") == 5)
  for width in [24, 30, 60, 120] {
    let text = fitStyledLine(
      "\u{1B}[38;2;4;5;6mℹ︎ " + String(repeating: "界😀e\u{301}", count: 80) + "\u{1B}[0m",
      width: width - 2)
    #expect(displayWidth(withoutStyling(text)) <= width - 2)
    #expect(text.hasSuffix("\u{1B}[0m"))
    let completion = fitNativeCompletion(
      "✔︎ Skipped verification (using existing appliance) [12.3s]", width: width - 2)
    #expect(displayWidth(completion) <= width - 2)
    #expect(completion.hasPrefix("✔︎ Skipped"))
    #expect(completion.hasSuffix("[12.3s]"))
  }
}

@Test func progressFallsBackSafelyWhenTerminalShrinksOrWidthIsUnknown() async throws {
  let capture = StartCapture()
  let columns = ProgressTestWidth()
  let sink = TerminalProgressSink(
    rendering: .animated, environment: ["TERM": "xterm", "NO_COLOR": ""], width: { columns.value },
    write: capture.streams.writeError)
  sink.startRefreshing()
  sink.emit(observation())
  try await Task.sleep(for: .milliseconds(150))
  columns.set(12)
  try await Task.sleep(for: .milliseconds(150))
  #expect(capture.error.contains("\u{1B}[?25h"))
  let offset = capture.error.count
  sink.emit(observation(detail: "new detail"))
  await sink.finish()
  #expect(!String(capture.error.dropFirst(offset)).contains("\u{1B}"))
  let unknown = StartCapture()
  let other = TerminalProgressSink(
    rendering: .animated, environment: ["TERM": "xterm"], width: { nil },
    write: unknown.streams.writeError)
  other.emit(observation())
  await other.finish()
  #expect(!unknown.error.contains("\u{1B}"))
}

@Test func sinkUsesNooraMeasuredBarAndStopsSparseRefreshBeforeSummary() async throws {
  let capture = StartCapture()
  let sink = TerminalProgressSink(
    rendering: .animated, environment: ["TERM": "xterm", "NO_COLOR": ""], width: { 160 },
    write: capture.streams.writeError)
  sink.startRefreshing()
  sink.emit(observation(.acquisition, bytes: 134_217_728, total: 268_435_456))
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !capture.error.contains("█"), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(capture.error.contains("█"))
  #expect(capture.error.contains("50%"))
  #expect(capture.error.contains("128.0 MiB / 256.0 MiB"))
  sink.emit(observation(.acquisition, .complete))
  await sink.finish(ready: true, connected: true)
  let finished = capture.error
  #expect(finished.contains("\u{1B}[?25h"))
  #expect(finished.contains("Startup: 1/9 stages resolved"))
  sink.emit(observation(detail: "late"))
  sink.cleanup()
  try await Task.sleep(for: .milliseconds(150))
  #expect(capture.error == finished)
}

@Test func sharedTerminalNooraWritesFinishBeforeSuccessErrorTimeoutAndCancellation() async throws {
  for outcome in ["success", "error", "timeout", "cancellation"] {
    var master: Int32 = 0
    var slave: Int32 = 0
    #expect(openpty(&master, &slave, nil, nil, nil) == 0)
    defer {
      close(master)
      close(slave)
    }
    var settings = termios()
    #expect(tcgetattr(slave, &settings) == 0)
    settings.c_oflag &= ~tcflag_t(ONLCR)
    #expect(tcsetattr(slave, TCSANOW, &settings) == 0)
    let output = slave
    let write: @Sendable (String) -> Void = { writeAll(output, Data($0.utf8)) }
    let sink = TerminalProgressSink(
      rendering: .animated, environment: ["TERM": "xterm", "NO_COLOR": ""], width: { 100 },
      write: write)
    sink.startRefreshing()
    sink.emit(observation())
    try await Task.sleep(for: .milliseconds(120))
    sink.emit(observation(.readiness, outcome == "success" ? .complete : .failed))
    await sink.finish(ready: outcome == "success", connected: outcome == "success")
    var streams = MacusStreams(writeOutput: write, writeError: write)
    streams.stdoutIsTTY = true
    streams.stderrIsTTY = true
    if outcome == "success" {
      HumanPresentation(streams: streams, environment: [:]).heading("Final summary")
    } else {
      HumanPresentation(streams: streams, environment: [:], error: true).failure(
        "Retained runtime", code: outcome)
    }
    sink.emit(observation(detail: "late"))
    sink.cleanup()
    _ = fcntl(master, F_SETFL, O_NONBLOCK)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = Darwin.read(master, &buffer, buffer.count)
      if count <= 0 { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    let text = String(decoding: data, as: UTF8.self)
    let restored = try #require(text.range(of: "\u{1B}[?25h"))
    let final = try #require(
      text.range(of: outcome == "success" ? "Final summary" : "Macus failed"))
    #expect(restored.lowerBound < final.lowerBound)
    #expect(!text[final.lowerBound...].contains("\u{1B}"))
    #expect(!text.contains("late"))
    #expect(text.contains("\n\r"))
  }
}

@Test func concurrentSinkEventsAreSerializedAndIgnoredAfterClose() async {
  let capture = StartCapture()
  let sink = TerminalProgressSink(
    rendering: .plain, stderrIsTTY: false, write: capture.streams.writeError)
  await withTaskGroup(of: Void.self) { group in
    for index in 0..<100 { group.addTask { sink.emit(observation(detail: "update \(index)")) } }
  }
  await sink.finish()
  let text = capture.error
  #expect(text.split(separator: "\n").filter { $0.contains("| update ") }.count == 100)
  #expect(text.contains("⨯ Waiting for Incus failed"))
  sink.emit(observation(detail: "late"))
  #expect(capture.error == text)
}

@Test func installationDiagnosticsPauseLiveLineAndRetainDeliberateBoundaries() async throws {
  let capture = StartCapture()
  let sink = TerminalProgressSink(
    rendering: .animated, environment: ["TERM": "xterm", "NO_COLOR": ""], width: { 100 },
    write: capture.streams.writeError)
  sink.emit(observation(.clientSetup))
  try await Task.sleep(for: .milliseconds(120))
  sink.diagnostic("Installing Incus\nwarning\u{1B}[2J\n")
  await sink.finish()
  #expect(capture.error.contains("  Installing Incus\n\r  warning\\u{001B}[2J\n\r"))
  #expect(!capture.error.contains("warning\u{1B}[2J"))
}

private final class ProgressTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private let start = ContinuousClock.now
  private var offset: Duration = .zero
  var value: ContinuousClock.Instant { lock.withLock { start.advanced(by: offset) } }
  func set(_ offset: Duration) { lock.withLock { self.offset = offset } }
}
private final class ProgressTestWidth: @unchecked Sendable {
  private let lock = NSLock()
  private var columns = 100
  var value: Int? { lock.withLock { columns } }
  func set(_ value: Int) { lock.withLock { columns = value } }
}
