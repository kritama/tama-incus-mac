import Foundation

// The event ledger is independent of event order; only complete/skipped stages resolve a slot.
enum ProgressRendering: Sendable, Equatable { case animated, plain, none }

extension StartupStage {
  var label: String {
    switch self {
    case .preflight: "Checking host"
    case .acquisition: "Downloading appliance"
    case .verification: "Verifying appliance"
    case .preparation: "Preparing appliance"
    case .serviceActivation: "Activating service"
    case .runtimeCreation: "Creating runtime"
    case .provisioning: "Provisioning Linux"
    case .readiness: "Waiting for Incus"
    case .clientSetup: "Connecting client"
    }
  }
}

struct ProgressRenderer: Sendable {
  var rendering: ProgressRendering
  private(set) var stages: [StartupStage: StartupStageState] = [:]
  private var operationID: String?
  private var cursorHidden = false
  private var closed = false
  private var lastRefresh: ContinuousClock.Instant?
  private var lastTransition: String?
  private var confirmedReady = false
  private var spinner = 0
  private var scrollback: Set<String> = []

  init(rendering: ProgressRendering) { self.rendering = rendering }

  var resolvedStages: Int {
    stages.filter {
      ($0.value == .complete || $0.value == .skipped)
        && ($0.key != .clientSetup || confirmedReady)
    }.count
  }

  static func resolve(selection: ProgressSelection, stderrIsTTY: Bool, term: String?, json: Bool)
    -> ProgressRendering
  {
    if selection == .none { return .none }
    let capable = stderrIsTTY && term != nil && term != "dumb" && term?.isEmpty == false
    return selection == .auto && capable && !json ? .animated : .plain
  }

  mutating func render(
    _ event: StartupProgressEvent, now: ContinuousClock.Instant, width: Int? = 100,
    measuredBar: String? = nil
  ) -> String? {
    guard !closed, rendering != .none else { return nil }
    if let operationID, operationID != event.operationID { return nil }
    operationID = event.operationID
    var event = event
    let old = stages[event.stage]
    // Late active/pending observations cannot unresolve a completed stage.
    if old != .complete && old != .skipped || event.state == .failed {
      stages[event.stage] = event.state
    } else if let old {
      event.state = old
    }
    let transition =
      "\(event.stage.rawValue)|\(event.state.rawValue)|\(event.detail ?? "")|\(event.expectedReboot)"
    let changed = transition != lastTransition
    let interval: Duration = rendering == .plain ? .seconds(5) : .milliseconds(100)
    if !changed, let lastRefresh, now < lastRefresh.advanced(by: interval) { return nil }
    lastRefresh = now
    lastTransition = transition
    let line = line(for: event)
    if rendering == .plain {
      return "[\(event.state.rawValue)] \(line)\n"
    }
    // Unknown/very narrow widths use plain output without risking wrapped stale rows.
    guard let width, width >= 24 else {
      let cleanup = restoreLine()
      rendering = .plain
      return cleanup + "[\(event.state.rawValue)] \(line)\n"
    }
    spinner = (spinner + 1) % 4
    let count = "\(resolvedStages)/9 stages"
    let bar =
      "[" + String(repeating: "#", count: resolvedStages)
      + String(repeating: "-", count: 9 - resolvedStages) + "]"
    let activity = ["|", "/", "-", "\\"][spinner]
    let full = "\(bar) \(count) | \(line)"
    var frame = full
    if let measuredBar, event.stage == .acquisition, event.state == .active,
      displayWidth(count + " | " + measuredBar) <= width - 2
    {
      frame = count + " | " + measuredBar
    }
    if displayWidth(frame) > width - 2 {
      frame = count + " | " + event.stage.label + " (\(humanDuration(event.elapsedSeconds)))"
    }
    if displayWidth(frame) > width - 2 { frame = count + " " + activity }
    let prefix = cursorHidden ? "" : "\u{1B}[?25l"
    cursorHidden = true
    var output = prefix + "\r\u{1B}[2K"
    if event.state == .complete || event.state == .skipped || event.state == .failed {
      if scrollback.insert(event.stage.rawValue + ":" + event.state.rawValue).inserted {
        output += fitCells("[\(event.state.rawValue)] " + line, width: width - 2) + "\n"
      }
    }
    output += fitCells(frame, width: width - 2)
    return output
  }

  mutating func confirm(ready: Bool, connected: Bool) -> String {
    guard !closed, ready && connected else { return "" }
    confirmedReady = true
    guard rendering != .none else { return "" }
    return restoreLine() + "[complete] \(resolvedStages)/9 stages | Macus is ready\n"
  }

  mutating func pauseLine() -> String { restoreLine() }

  mutating func cleanup() -> String {
    guard !closed else { return "" }
    closed = true
    return restoreLine()
  }
  private mutating func restoreLine() -> String {
    guard cursorHidden else { return "" }
    cursorHidden = false
    return "\r\u{1B}[2K\u{1B}[?25h"
  }

  private func line(for event: StartupProgressEvent) -> String {
    var text = event.expectedReboot ? "Waiting for expected kernel reboot" : event.stage.label
    if let completed = event.completedBytes {
      let safe = max(0, completed)
      if let total = event.totalBytes, total > 0 {
        let bounded = min(safe, total)
        let percent = Int((Double(bounded) / Double(total) * 100).rounded(.down))
        text += " \(humanBytes(safe)) / \(humanBytes(total)), \(percent)%"
      } else {
        text += " \(humanBytes(safe))"
      }
    }
    if event.state == .active { text += " (\(humanDuration(event.elapsedSeconds)))" }
    if let detail = event.detail, !detail.isEmpty { text += " | " + readableDetail(detail) }
    return text
  }
}

func readableDetail(_ detail: String) -> String {
  switch detail {
  case "packages": "Installing guest packages"
  case "storage": "Preparing guest storage"
  case "incus": "Starting Incus"
  case "kernel_transition": "Waiting for kernel restart"
  default: terminalSafe(detail)
  }
}

/// Conservative cell budgeting, including wide scripts, emoji and combining sequences.
func displayWidth(_ value: String) -> Int {
  value.reduce(0) { $0 + characterWidth($1) }
}
private func characterWidth(_ character: Character) -> Int {
  let scalars = character.unicodeScalars
  if scalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark }) { return 0 }
  return scalars.contains {
    let v = $0.value
    return $0.properties.isEmojiPresentation || v == 0xFE0F || (0x1100...0x115F).contains(v)
      || (0x2E80...0xA4CF).contains(v)
      || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
      || (0xFE10...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
      || (0x1F000...0x1FAFF).contains(v) || v >= 0x20000
  } ? 2 : 1
}
func fitCells(_ value: String, width: Int) -> String {
  var result = ""
  var used = 0
  for character in value {
    let cells = characterWidth(character)
    if used + cells > width { break }
    result.append(character)
    used += cells
  }
  return result
}
