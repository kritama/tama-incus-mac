import Foundation
import Testing

@testable import Macus

@Test func homebrewServiceUsesValidatedOptPath() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let binary = root.appendingPathComponent("Cellar/macus/0.1/bin/macus")
  try FileManager.default.createDirectory(
    at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("fixture".utf8).write(to: binary)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
  let opt = root.appendingPathComponent("opt/macus")
  try FileManager.default.createDirectory(
    at: opt.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    at: opt, withDestinationURL: binary.deletingLastPathComponent().deletingLastPathComponent())
  let physical = binary.resolvingSymlinksInPath().path
  let stable = root.resolvingSymlinksInPath().appendingPathComponent("opt/macus/bin/macus").path
  #expect(ServiceExecutable.stablePath(for: physical) == stable)
  #expect(ServiceExecutable.matches(reported: physical, expected: stable))
  #expect(ServiceExecutable.matches(reported: stable, expected: stable))
  #expect(!ServiceExecutable.matches(reported: "/other/macus", expected: stable))
  #expect(!ServiceExecutable.matches(reported: stable, expected: physical))

  let next = root.appendingPathComponent("Cellar/macus/0.2/bin/macus")
  try FileManager.default.createDirectory(
    at: next.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("next".utf8).write(to: next)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: next.path)
  try FileManager.default.removeItem(at: opt)
  try FileManager.default.createSymbolicLink(
    at: opt, withDestinationURL: next.deletingLastPathComponent().deletingLastPathComponent())
  #expect(ServiceExecutable.stablePath(for: physical) == physical)
  #expect(!ServiceExecutable.matches(reported: physical, expected: stable))
  #expect(ServiceExecutable.stablePath(for: next.resolvingSymlinksInPath().path) == stable)
}

@Test func ordinarySymlinksDoNotRelaxServiceIdentity() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let alias = root.appendingPathComponent("macus")
  try FileManager.default.createSymbolicLink(
    at: alias, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
  #expect(ServiceExecutable.stablePath(for: "/usr/bin/true") == "/usr/bin/true")
  #expect(!ServiceExecutable.matches(reported: "/usr/bin/true", expected: alias.path))
}
