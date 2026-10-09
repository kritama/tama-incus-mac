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
  var renderer = ProgressRenderer(rendering: .animated)
  let now = ContinuousClock.now
  let stages: [StartupStage] = [
    .preflight, .acquisition, .verification, .preparation,
    .serviceActivation, .runtimeCreation, .provisioning, .readiness, .clientSetup,
  ]
  for stage in stages {
    _ = renderer.render(observation(stage, .skipped), now: now)
    _ = renderer.render(observation(stage, .skipped), now: now)
  }
  #expect(renderer.resolvedStages == 8)
  let late = renderer.render(observation(.provisioning), now: now) ?? ""
  #expect(renderer.resolvedStages == 8)
  #expect(!late.contains("9/9"))
  #expect(!late.contains("%"))
  #expect(renderer.confirm(ready: true, connected: false).isEmpty)
  #expect(renderer.confirm(ready: true, connected: true).contains("9/9 stages"))
  #expect(renderer.resolvedStages == 9)
  _ = renderer.cleanup()
  #expect(renderer.cleanup().isEmpty)
  #expect(renderer.render(observation(), now: now) == nil)

  var failed = ProgressRenderer(rendering: .plain)
  _ = failed.render(observation(.readiness, .failed, detail: "not ready"), now: now)
  #expect(failed.resolvedStages == 0)
  #expect(failed.confirm(ready: false, connected: false).isEmpty)
}

@Test func measuredCountersAreBoundedAndUnknownWaitsRemainActivities() {
  let now = ContinuousClock.now
  for (bytes, total, expected) in [
    (Int64(-4), Int64(8), "0%"), (4, 8, "50%"), (12, 8, "100%"), (Int64.max, Int64.max, "100%"),
  ] {
    var renderer = ProgressRenderer(rendering: .plain)
    let text =
      renderer.render(observation(.acquisition, bytes: bytes, total: total), now: now) ?? ""
    #expect(text.contains(expected))
    #expect(renderer.resolvedStages == 0)
  }
  for total: Int64? in [nil, 0, -1] {
    var renderer = ProgressRenderer(rendering: .plain)
    let text = renderer.render(observation(.acquisition, bytes: 128, total: total), now: now) ?? ""
    #expect(text.contains("128 bytes"))
    #expect(!text.contains("%"))
  }
  var renderer = ProgressRenderer(rendering: .plain)
  let wait = renderer.render(observation(detail: "packages", reboot: true), now: now) ?? ""
  #expect(wait.contains("Waiting for expected kernel reboot"))
  #expect(wait.contains("1m 12s"))
  #expect(wait.contains("Installing guest packages"))
  #expect(!wait.contains("%"))
}

@Test func plainProgressThrottlesRepeatedUpdatesAndKeepsTransitions() {
  var renderer = ProgressRenderer(rendering: .plain)
  let now = ContinuousClock.now
  #expect(renderer.render(observation(.acquisition, bytes: 1), now: now) != nil)
  for step in 1..<50 {
    #expect(
      renderer.render(
        observation(.acquisition, bytes: Int64(step)),
        now: now.advanced(by: .milliseconds(step * 100))) == nil)
  }
  #expect(
    renderer.render(observation(.acquisition, bytes: 80), now: now.advanced(by: .seconds(5))) != nil
  )
  #expect(
    renderer.render(
      observation(.acquisition, bytes: 81, detail: "new detail"),
      now: now.advanced(by: .milliseconds(5_001))) != nil)
  #expect(
    renderer.render(
      observation(.acquisition, .complete), now: now.advanced(by: .milliseconds(5_002))) != nil)
}

@Test func progressFitsNarrowUnicodeWidthsAndSafelyFallsBackAfterResize() {
  let now = ContinuousClock.now
  for width in [24, 30, 60, 120] {
    var renderer = ProgressRenderer(rendering: .animated)
    let text =
      renderer.render(
        observation(detail: String(repeating: "界😀e\u{301}", count: 80)), now: now, width: width)
      ?? ""
    let frame = text.components(separatedBy: "\u{1B}[2K").last ?? ""
    #expect(displayWidth(frame) <= width - 2)
  }
  #expect(displayWidth("界😀e\u{301}") == 5)
  var renderer = ProgressRenderer(rendering: .animated)
  _ = renderer.render(observation(), now: now, width: 100)
  let resized = renderer.render(observation(detail: "changed"), now: now, width: 12) ?? ""
  #expect(resized.contains("\u{1B}[?25h"))
  let plain = renderer.render(observation(detail: "another"), now: now, width: 100) ?? ""
  #expect(!plain.contains("\u{1B}"))
  var unknown = ProgressRenderer(rendering: .animated)
  #expect(!(unknown.render(observation(), now: now, width: nil) ?? "").contains("\u{1B}"))
}

@Test func sinkUsesNooraMeasuredBarAndStopsSparseRefreshBeforeSummary() async throws {
  let capture = StartCapture()
  let sink = TerminalProgressSink(
    rendering: .animated, environment: ["TERM": "xterm", "NO_COLOR": ""], width: { 160 },
    write: capture.streams.writeError)
  sink.startRefreshing()
  sink.emit(observation(.acquisition, bytes: 134_217_728, total: 268_435_456))
  try await Task.sleep(for: .milliseconds(250))
  #expect(capture.error.contains("█"))
  #expect(capture.error.contains("50%"))
  #expect(capture.error.contains("128.0 MiB / 256.0 MiB"))
  await sink.finish(ready: true, connected: true)
  let finished = capture.error
  #expect(finished.contains("\u{1B}[?25h"))
  #expect(finished.hasSuffix("Macus is ready\n"))
  sink.emit(observation(detail: "late"))
  sink.cleanup()
  try await Task.sleep(for: .milliseconds(250))
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
    let output = slave
    let write: @Sendable (String) -> Void = { writeAll(output, Data($0.utf8)) }
    let sink = TerminalProgressSink(
      rendering: .animated, environment: ["TERM": "xterm", "NO_COLOR": ""], width: { 100 },
      write: write)
    sink.startRefreshing()
    sink.emit(observation())
    await sink.finish(ready: outcome == "success", connected: outcome == "success")
    let streams = MacusStreams(writeOutput: write, writeError: write)
    if outcome == "success" {
      HumanPresentation(streams: streams, environment: [:]).heading("Final summary")
    } else {
      HumanPresentation(streams: streams, environment: [:], error: true).failure(
        "Retained runtime", code: outcome)
    }
    sink.emit(observation(detail: "late"))
    sink.cleanup()
    try await Task.sleep(for: .milliseconds(120))
    _ = fcntl(master, F_SETFL, O_NONBLOCK)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
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
    #expect(text.contains("\r\n"))
  }
}

@Test func concurrentSinkEventsAreSerializedAndIgnoredAfterClose() async {
  let capture = StartCapture()
  let sink = TerminalProgressSink(rendering: .plain, write: capture.streams.writeError)
  await withTaskGroup(of: Void.self) { group in
    for index in 0..<100 {
      group.addTask { sink.emit(observation(detail: "update \(index)")) }
    }
  }
  await sink.finish()
  let text = capture.error
  #expect(text.split(separator: "\n").count == 100)
  #expect(text.split(separator: "\n").allSatisfy { $0.hasPrefix("[active] Waiting for Incus") })
  sink.emit(observation(detail: "late"))
  #expect(capture.error == text)
}

@Test func installationDiagnosticsPauseLiveLineAndRetainDeliberateBoundaries() async {
  let capture = StartCapture()
  let sink = TerminalProgressSink(
    rendering: .animated, environment: ["TERM": "xterm", "NO_COLOR": ""], width: { 100 },
    write: capture.streams.writeError)
  sink.emit(observation(.clientSetup))
  sink.diagnostic("Installing Incus\nwarning\u{1B}[2J\n")
  await sink.finish()
  #expect(capture.error.contains("\u{1B}[?25h  Installing Incus\n  warning\\u{001B}[2J\n"))
  #expect(!capture.error.contains("warning\u{1B}[2J"))
}
