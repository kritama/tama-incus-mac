import Foundation

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

enum ProgressRenderer {
  static func resolve(selection: ProgressSelection, stderrIsTTY: Bool, term: String?, json: Bool)
    -> ProgressRendering
  {
    if selection == .none { return .none }
    let capable = stderrIsTTY && term != nil && term != "dumb" && term?.isEmpty == false
    return selection == .auto && capable && !json ? .animated : .plain
  }
}

struct ProgressLedger: Sendable {
  private(set) var stages: [StartupStage: StartupStageState] = [:]
  private var operationID: String?
  private var confirmedReady = false
  var resolvedStages: Int {
    stages.filter {
      ($0.value == .complete || $0.value == .skipped) && ($0.key != .clientSetup || confirmedReady)
    }.count
  }
  mutating func observe(_ event: StartupProgressEvent) -> Bool {
    if let operationID, operationID != event.operationID { return false }
    operationID = event.operationID
    if let previous = stages[event.stage],
      previous == .complete || previous == .skipped || previous == .failed
    {
      return false
    }
    stages[event.stage] = event.state
    return true
  }
  mutating func confirm(ready: Bool, connected: Bool) { confirmedReady = ready && connected }
  var count: String { "\(resolvedStages)/9 stages" }
  var bar: String {
    "[" + String(repeating: "#", count: resolvedStages)
      + String(repeating: "-", count: 9 - resolvedStages) + "]"
  }
}

extension StartupStage {
  var successLabel: String {
    switch self {
    case .preflight: "Host checked"
    case .acquisition: "Appliance downloaded"
    case .verification: "Appliance verified"
    case .preparation: "Appliance prepared"
    case .serviceActivation: "Service activated"
    case .runtimeCreation: "Runtime created"
    case .provisioning: "Linux provisioned"
    case .readiness: "Incus is ready"
    case .clientSetup: "Client connected"
    }
  }
  var skippedLabel: String {
    switch self {
    case .acquisition: "Skipped download (using existing appliance)"
    case .verification: "Skipped verification (using existing appliance)"
    case .preparation: "Skipped preparation (using existing appliance)"
    case .runtimeCreation: "Skipped creation (using existing runtime)"
    case .provisioning: "Skipped provisioning (Linux already ready)"
    default: label + " (skipped)"
    }
  }
}

func byteProgress(_ event: StartupProgressEvent) -> String? {
  guard event.stage == .acquisition, let completed = event.completedBytes else { return nil }
  let safe = max(0, completed)
  guard let total = event.totalBytes, total > 0 else { return humanBytes(safe) }
  let percent = Int((Double(min(safe, total)) / Double(total) * 100).rounded(.down))
  return "\(humanBytes(safe)) / \(humanBytes(total)), \(percent)%"
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

func withoutStyling(_ value: String) -> String {
  value.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
}

func fitStyledLine(_ value: String, width: Int) -> String {
  guard displayWidth(withoutStyling(value)) > width else { return value }
  var result = ""
  var used = 0
  var index = value.startIndex
  while index < value.endIndex {
    if let escape = value.range(
      of: "\u{1B}\\[[0-9;]*m", options: [.regularExpression, .anchored],
      range: index..<value.endIndex)
    {
      result += value[escape]
      index = escape.upperBound
      continue
    }
    let character = value[index]
    let cells = characterWidth(character)
    guard used + cells <= width else { break }
    result.append(character)
    used += cells
    index = value.index(after: index)
  }
  if value.contains("\u{1B}") { result += "\u{1B}[0m" }
  return result
}

func fitNativeCompletion(_ value: String, width: Int) -> String {
  let plain = withoutStyling(value)
  guard displayWidth(plain) > width,
    let elapsed = plain.range(of: " \\[([0-9]+)(\\.[0-9]+)?s\\]$", options: .regularExpression)
  else { return fitStyledLine(value, width: width) }
  let suffix = String(plain[elapsed])
  return fitCells(String(plain[..<elapsed.lowerBound]), width: max(0, width - displayWidth(suffix)))
    + suffix
}
