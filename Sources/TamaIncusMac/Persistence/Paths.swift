import Darwin
import Foundation

public struct RuntimePaths: Sendable {
  public let directory: URL
  public init(directory: URL) { self.directory = directory.standardizedFileURL }
  public var config: URL { directory.appendingPathComponent("config.json") }
  public var runtimeDirectory: URL {
    directory.appendingPathComponent("runtime", isDirectory: true)
  }
  public var rootDisk: URL { runtimeDirectory.appendingPathComponent("root.raw") }
  public var dataDisk: URL { runtimeDirectory.appendingPathComponent("data.raw") }
  public var efiStore: URL { runtimeDirectory.appendingPathComponent("efi.bin") }
  public var seed: URL { runtimeDirectory.appendingPathComponent("seed.iso") }
  public var serialLog: URL { directory.appendingPathComponent("serial.log") }
  public var controlSocket: URL { directory.appendingPathComponent("runtime.sock") }
  public var incusSocket: URL { directory.appendingPathComponent("incus.sock") }

  public func prepare() throws {
    guard directory.isFileURL else {
      throw RuntimeError(.invalidConfiguration, "State must be a local file URL")
    }
    // Validate every existing ancestor, including a symlink below an otherwise trusted parent.
    var ancestor = directory
    while ancestor.path != "/" {
      var info = stat()
      if lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
        // Darwin's standard /var and /tmp aliases are trusted ancestors, never custom links.
        if ancestor != directory, ["/var", "/tmp"].contains(ancestor.path),
          try FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path) == "private"
            + ancestor.path
        {
          ancestor.deleteLastPathComponent()
          continue
        }
        throw RuntimeError(
          .invalidConfiguration, "Symlink state paths are unsupported: \(ancestor.path)")
      }
      ancestor.deleteLastPathComponent()
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
      guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
        attributes[.type] as? FileAttributeType == .typeDirectory
      else {
        throw RuntimeError(.invalidConfiguration, "State directory must belong to this user")
      }
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard chmod(directory.path, 0o700) == 0 else {
      throw RuntimeError(.io, "Cannot secure state directory")
    }
    for endpoint in [controlSocket, incusSocket] {
      guard endpoint.path.utf8.count < 104 else {
        throw RuntimeError(
          .invalidConfiguration,
          "Unix socket path exceeds 103 bytes; choose a shorter state directory")
      }
    }
  }
}

public final class StateLock {
  private let descriptor: Int32
  public init(paths: RuntimePaths) throws {
    try paths.prepare()
    descriptor = open(
      paths.directory.appendingPathComponent("daemon.lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw RuntimeError(.io, "Cannot open state lock") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw RuntimeError(.conflict, "Another daemon owns this state directory")
    }
  }
  deinit { close(descriptor) }
}
