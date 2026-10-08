import Foundation

/// Homebrew owns a stable opt link; source installations retain their physical executable path.
enum ServiceExecutable {
  static func stablePath(for physicalPath: String) -> String {
    let binary = URL(fileURLWithPath: physicalPath)
    let bin = binary.deletingLastPathComponent()
    let version = bin.deletingLastPathComponent()
    let rack = version.deletingLastPathComponent()
    let cellar = rack.deletingLastPathComponent()
    guard binary.lastPathComponent == "macus", bin.lastPathComponent == "bin",
      rack.lastPathComponent == "macus", cellar.lastPathComponent == "Cellar",
      !version.lastPathComponent.isEmpty
    else { return physicalPath }
    let stable = cellar.deletingLastPathComponent().appendingPathComponent("opt/macus/bin/macus")
    guard FileManager.default.isExecutableFile(atPath: stable.path),
      stable.resolvingSymlinksInPath().path == binary.path
    else { return physicalPath }
    return stable.path
  }

  static func matches(reported: String, expected: String) -> Bool {
    if reported == expected { return true }
    let physical = URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
    // Only a verified Homebrew opt path may have an alternate physical representation.
    // An arbitrary symlink or an old keg registration remains a conflict.
    guard expected != physical, stablePath(for: physical) == expected else { return false }
    return reported == physical
  }
}
