import Foundation

enum ProgressRendering: Sendable, Equatable {
  case animated
  case plain
  case none
}

struct ProgressRenderer: Sendable {
  var rendering: ProgressRendering
  private var cursorHidden = false
  private var lastRefresh: ContinuousClock.Instant?
  private var spinner = 0
  private let frames = ["|", "/", "-", "\\"]

  init(rendering: ProgressRendering) { self.rendering = rendering }

  static func resolve(selection: ProgressSelection, stderrIsTTY: Bool, term: String?, json: Bool)
    -> ProgressRendering
  {
    if selection == .none { return .none }
    let capable = stderrIsTTY && term != nil && term != "dumb" && term?.isEmpty == false
    if selection == .auto && capable && !json { return .animated }
    return .plain
  }

  mutating func render(_ event: StartupProgressEvent, now: ContinuousClock.Instant) -> String? {
    guard rendering != .none else { return nil }
    let changed = event.state != .active || event.completedBytes == nil
    if event.state == .active, event.completedBytes != nil, let lastRefresh,
      now < lastRefresh.advanced(by: .milliseconds(100)), !changed
    {
      return nil
    }
    if event.state == .active, event.completedBytes != nil { lastRefresh = now }
    let line = line(for: event)
    switch rendering {
    case .none:
      return nil
    case .plain:
      return line + "\n"
    case .animated:
      spinner = (spinner + 1) % frames.count
      let prefix = cursorHidden ? "" : "\u{1B}[?25l"
      cursorHidden = true
      return prefix + "\r\u{1B}[2K" + frames[spinner] + " " + line
    }
  }

  mutating func cleanup() -> String {
    guard rendering == .animated, cursorHidden else { return "" }
    cursorHidden = false
    return "\r\u{1B}[2K\u{1B}[?25h"
  }

  private func line(for event: StartupProgressEvent) -> String {
    var text = "\(event.stage.rawValue): \(event.state.rawValue)"
    if let completed = event.completedBytes {
      if let total = event.totalBytes, total > 0 {
        let percent = Int((Double(completed) / Double(total) * 100).rounded(.down))
        text += " \(completed)/\(total) bytes \(percent)%"
      } else {
        text += " \(completed) bytes"
      }
    } else if event.state == .active {
      text += " elapsed \(event.elapsedSeconds)s"
    }
    if event.expectedReboot { text += " expected reboot" }
    if let detail = event.detail, !detail.isEmpty {
      text += " \(terminalSafe(String(detail.prefix(160))))"
    }
    return text
  }
}
