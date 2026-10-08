import Darwin
import Foundation

struct BootstrapJournal: Codable, Sendable, Equatable {
  var schemaVersion: Int = 1
  var catalogID: String
  var payloadRevision: String
  var archiveSHA512: String
  var rawSHA256: String
  var acquired: Bool
  var prepared: Bool
}

enum BootstrapStore {
  static func journalURL(_ directory: URL) -> URL {
    directory.appendingPathComponent("bootstrap-journal.json")
  }

  static func loadJournal(_ directory: URL) throws -> BootstrapJournal? {
    let url = journalURL(directory)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    try requireOwnedRegular(url)
    return try JSON.decoder().decode(BootstrapJournal.self, from: Data(contentsOf: url))
  }

  static func saveJournal(_ journal: BootstrapJournal, directory: URL) throws {
    let url = journalURL(directory)
    try JSON.encoder().encode(journal).write(to: url, options: .atomic)
    guard chmod(url.path, 0o600) == 0 else {
      throw RuntimeError(.io, "Cannot secure bootstrap journal")
    }
  }

  static func existingRuntime(_ directory: URL) throws -> ExistingRuntime {
    let paths = RuntimePaths(directory: directory)
    let configExists = FileManager.default.fileExists(atPath: paths.config.path)
    let rootExists = FileManager.default.fileExists(atPath: paths.rootDisk.path)
    let dataExists = FileManager.default.fileExists(atPath: paths.dataDisk.path)
    let runtimeExists = FileManager.default.fileExists(atPath: paths.runtimeDirectory.path)
    if configExists {
      try requireOwnedRegular(paths.config)
      guard rootExists, dataExists else {
        throw RuntimeError(
          .io,
          "Incomplete runtime; preserve data and recover or explicitly delete. macus start will not reset it."
        )
      }
      try requireOwnedRegular(paths.rootDisk)
      try requireOwnedRegular(paths.dataDisk)
      return .existing
    }
    if runtimeExists || rootExists || dataExists {
      throw RuntimeError(
        .io,
        "Owned runtime disks exist without committed configuration. Preserve those files; macus start will not create or reset another runtime."
      )
    }
    return .absent
  }
}

enum ExistingRuntime: Sendable { case absent, existing }

final class BootstrapLock: @unchecked Sendable {
  private var descriptor: Int32
  init(directory: URL) throws {
    let url = directory.appendingPathComponent("bootstrap.lock")
    descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw RuntimeError(.io, "Cannot open bootstrap lock") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      descriptor = -1
      throw RuntimeError(.conflict, "Another macus start owns this state directory")
    }
  }
  func release() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
  }
  deinit { release() }
}

extension BootstrapStore {
  static func validateState(_ directory: URL) throws {
    guard directory.isFileURL, directory.path.hasPrefix("/") else {
      throw RuntimeError(.invalidConfiguration, "State must be an absolute local directory")
    }
    var ancestor = directory.standardizedFileURL
    while ancestor.path != "/" {
      var info = stat()
      if lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
        if ancestor != directory.standardizedFileURL, ["/var", "/tmp"].contains(ancestor.path),
          (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == "private"
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
      var info = stat()
      guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == getuid()
      else {
        throw RuntimeError(.invalidConfiguration, "State directory must belong to this user")
      }
    }
    let paths = RuntimePaths(directory: directory)
    for endpoint in [paths.controlSocket, paths.incusSocket] where endpoint.path.utf8.count >= 104 {
      throw RuntimeError(
        .invalidConfiguration,
        "Unix socket path exceeds 103 bytes; choose a shorter state directory"
      )
    }
  }
}
