import CryptoKit
import Foundation

protocol ApplianceDownloader: Sendable {
  func download(
    url: URL, to destination: URL, maximumBytes: Int64, deadline: ContinuousClock.Instant,
    onBytes: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws
}

struct URLSessionApplianceDownloader: ApplianceDownloader {
  func download(
    url: URL, to destination: URL, maximumBytes: Int64, deadline: ContinuousClock.Instant,
    onBytes: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws {
    let session = StreamingDownload()
    try await session.download(
      url: url, to: destination, maximumBytes: maximumBytes, deadline: deadline, onBytes: onBytes)
  }
}

struct ApplianceAcquisition {
  var downloader: any ApplianceDownloader

  func materialize(
    entry: ApplianceCatalogEntry, directory: URL, budget: StartupBudget,
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    onBytes: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws -> URL {
    let cache = directory.appendingPathComponent("appliance-cache", isDirectory: true)
      .appendingPathComponent(entry.id, isDirectory: true)
    if try cacheIsValid(cache, entry: entry) { return cache }
    if FileManager.default.fileExists(atPath: cache.path) {
      let rejected = directory.appendingPathComponent(
        "appliance-cache-rejected-\(UUID().uuidString)")
      try FileManager.default.moveItem(at: cache, to: rejected)
    }
    let staging = directory.appendingPathComponent("appliance-staging-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      let archive = staging.appendingPathComponent(entry.archiveName)
      FileManager.default.createFile(
        atPath: archive.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let deadline = budget.deadline
      try await downloader.download(
        url: entry.archiveURL, to: archive, maximumBytes: entry.archiveBytes, deadline: deadline,
        onBytes: onBytes)
      guard try fileSize(archive) == entry.archiveBytes else {
        throw RuntimeError(
          .invalidConfiguration, "Appliance archive size does not match the catalog")
      }
      guard try sha512(archive) == entry.archiveSHA512 else {
        throw RuntimeError(
          .invalidConfiguration, "Appliance archive SHA-512 does not match the catalog")
      }
      let raw = staging.appendingPathComponent("disk.raw")
      try await TarArchive.extractGzip(
        archive: archive, member: entry.memberName, expectedBytes: entry.rawBytes, to: raw,
        deadline: budget.deadline)
      guard try sha256(raw) == entry.rawSHA256 else {
        throw RuntimeError(
          .invalidConfiguration, "Extracted disk SHA-256 does not match the catalog")
      }
      let root = staging.appendingPathComponent("root.raw")
      try FileManager.default.copyItem(at: raw, to: root)
      guard chmod(root.path, 0o600) == 0 else {
        throw RuntimeError(.io, "Cannot secure cached root disk")
      }
      try? FileManager.default.removeItem(at: archive)
      try? FileManager.default.removeItem(at: raw)
      try FileManager.default.createDirectory(
        at: cache.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.moveItem(at: staging, to: cache)
      _ = now
      return cache
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }

  private func cacheIsValid(_ cache: URL, entry: ApplianceCatalogEntry) throws -> Bool {
    let root = cache.appendingPathComponent("root.raw")
    guard FileManager.default.fileExists(atPath: root.path) else { return false }
    try requireOwnedRegular(root)
    guard try fileSize(root) == entry.rawBytes, try sha256(root) == entry.rawSHA256 else {
      return false
    }
    return true
  }
}

func sha256(_ url: URL) throws -> String {
  try hash(url, SHA256())
}

func sha512(_ url: URL) throws -> String {
  try hash(url, SHA512())
}

private func hash<H: HashFunction>(_ url: URL, _ hasher: H) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hasher = hasher
  while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
    hasher.update(data: chunk)
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func fileSize(_ url: URL) throws -> Int64 {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.size] as? NSNumber)?.int64Value ?? -1
}

func requireOwnedRegular(_ url: URL) throws {
  var info = stat()
  guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid()
  else { throw RuntimeError(.invalidConfiguration, "Expected an owned regular file: \(url.path)") }
}

private final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var file: FileHandle?
  private var task: URLSessionTask?
  private var session: URLSession?
  private var count: Int64 = 0
  private var total: Int64?
  private var maximum: Int64 = 0
  private var deadline = ContinuousClock.now
  private var onBytes: (@Sendable (Int64, Int64?) -> Void)?
  private var finished = false

  func download(
    url: URL, to destination: URL, maximumBytes: Int64, deadline: ContinuousClock.Instant,
    onBytes: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws {
    maximum = maximumBytes
    self.deadline = deadline
    self.onBytes = onBytes
    file = try FileHandle(forWritingTo: destination)
    let configuration = URLSessionConfiguration.ephemeral
    let remaining = ContinuousClock.now.duration(to: deadline).components.seconds
    configuration.timeoutIntervalForRequest = Double(max(remaining, 1))
    configuration.timeoutIntervalForResource = Double(max(remaining, 1))
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    self.session = session
    let task = session.dataTask(with: url)
    self.task = task
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      fail(RuntimeError(.io, "Appliance download failed with HTTP \(http.statusCode)"))
      completionHandler(.cancel)
      return
    }
    let length = response.expectedContentLength
    if length > maximum {
      fail(RuntimeError(.invalidConfiguration, "Appliance download exceeds the catalog size"))
      completionHandler(.cancel)
      return
    }
    if length == maximum { total = length }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    if ContinuousClock.now >= deadline || Task.isCancelled {
      fail(RuntimeError(.timeout, "Appliance download deadline exceeded"))
      dataTask.cancel()
      return
    }
    count += Int64(data.count)
    if count > maximum {
      fail(RuntimeError(.invalidConfiguration, "Appliance download exceeds the catalog size"))
      dataTask.cancel()
      return
    }
    do {
      try file?.write(contentsOf: data)
      onBytes?(count, total)
    } catch {
      fail(RuntimeError(.io, "Cannot write appliance download"))
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    session.finishTasksAndInvalidate()
    if let error {
      fail(error)
    } else if count != maximum {
      fail(
        RuntimeError(.invalidConfiguration, "Appliance download size does not match the catalog"))
    } else {
      succeed()
    }
  }

  private func succeed() { finish(nil) }
  private func fail(_ error: Error) { finish(error) }
  private func finish(_ error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    finished = true
    try? file?.close()
    if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
    continuation = nil
  }
}
