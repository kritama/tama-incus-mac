import Darwin
import Foundation

public struct StateStore: Sendable {
  public let paths: RuntimePaths
  public init(paths: RuntimePaths) { self.paths = paths }
  public func load() throws -> RuntimeConfiguration? {
    if try resetIsPending() {
      try finishReset()
      return nil
    }
    guard FileManager.default.fileExists(atPath: paths.config.path) else { return nil }
    try requireRegularFile(paths.config)
    let value = try JSON.decoder().decode(
      RuntimeConfiguration.self, from: Data(contentsOf: paths.config))
    try value.validate()
    guard FileManager.default.fileExists(atPath: paths.rootDisk.path),
      FileManager.default.fileExists(atPath: paths.dataDisk.path)
    else {
      throw RuntimeError(.io, "Incomplete runtime; preserve data and recover or explicitly delete")
    }
    return value
  }
  public func save(_ configuration: RuntimeConfiguration) throws {
    try configuration.validate()
    try JSON.encoder().encode(configuration).write(to: paths.config, options: .atomic)
    guard chmod(paths.config.path, 0o600) == 0 else {
      throw RuntimeError(.io, "Cannot secure configuration")
    }
  }
  public func resizeData(gib: UInt64) throws {
    try Self.growDisk(paths.dataDisk, bytes: gib * 1024 * 1024 * 1024)
  }
  public static func growDisk(_ url: URL, bytes: UInt64, create: Bool = false) throws {
    let descriptor = open(
      url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT | O_EXCL : 0), 0o600)
    guard descriptor >= 0 else { throw RuntimeError(.io, "Cannot open disk: \(url.path)") }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_size >= 0, UInt64(info.st_size) <= bytes,
      bytes <= UInt64(Int64.max)
    else { throw RuntimeError(.invalidConfiguration, "Disk shrink or unsafe file refused") }
    guard ftruncate(descriptor, off_t(bytes)) == 0, fsync(descriptor) == 0 else {
      throw RuntimeError(.io, "Disk growth failed")
    }
  }
  // Persisted compatibility marker: keep readable across the Macus rename.
  private static let confirmedReset = Data("tama-incus-mac confirmed reset v1\n".utf8)

  /// Called only after the service verifies explicit confirmation and a stopped VM.
  /// Publish durable intent before touching disks, so a crash cannot strand configuration.
  func beginReset() throws {
    if try resetIsPending() { return }
    try Self.confirmedReset.write(to: paths.resetIntent, options: .atomic)
    guard chmod(paths.resetIntent.path, 0o600) == 0 else {
      throw RuntimeError(.io, "Cannot secure reset intent")
    }
    try syncFile(paths.resetIntent)
    try syncFile(paths.directory)
  }
  private func resetIsPending() throws -> Bool {
    var info = stat()
    if lstat(paths.resetIntent.path, &info) != 0 {
      guard errno == ENOENT else { throw RuntimeError(.io, "Cannot inspect reset intent") }
      return false
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_size == Self.confirmedReset.count,
      try Data(contentsOf: paths.resetIntent) == Self.confirmedReset
    else { throw RuntimeError(.invalidConfiguration, "Invalid reset intent; preserve data") }
    return true
  }
  private func syncFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RuntimeError(.io, "Cannot open reset state for sync") }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw RuntimeError(.io, "Cannot sync reset state") }
  }
  public func delete() throws {
    try beginReset()
    try finishReset()
  }
  private func finishReset() throws {
    // Fail before deleting disks if allowance bookkeeping is a symlink or foreign file.
    try RebootAllowanceStore.rejectUnsafeForConfirmedReset(paths: paths)
    if FileManager.default.fileExists(atPath: paths.runtimeDirectory.path) {
      try FileManager.default.removeItem(at: paths.runtimeDirectory)
    }
    if FileManager.default.fileExists(atPath: paths.config.path) {
      try FileManager.default.removeItem(at: paths.config)
    }
    try RebootAllowanceStore.removeAfterConfirmedReset(paths: paths)
    try syncFile(paths.directory)
    try FileManager.default.removeItem(at: paths.resetIntent)
    try syncFile(paths.directory)
  }
}

func requireRegularFile(_ url: URL) throws {
  var info = stat()
  guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
    throw RuntimeError(.invalidConfiguration, "Expected a regular file: \(url.path)")
  }
}
