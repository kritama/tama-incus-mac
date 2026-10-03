import CryptoKit
import Darwin
import Foundation

public struct ApplianceManifest: Codable, Sendable {
  public let schemaVersion: Int
  public let id: String
  public let architecture: String
  public let rootDisk: String
  public let sha256: String
  public let vsockProtocol: Int
}

public enum GuestImageManager {
  public static func verify(manifestURL: URL) throws -> URL {
    try verifiedImage(manifestURL: manifestURL).0
  }

  private static func verifiedImage(manifestURL: URL) throws -> (URL, ApplianceManifest) {
    try requireRegularFile(manifestURL)
    let manifest = try JSON.decoder().decode(
      ApplianceManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.schemaVersion == 1, manifest.architecture == "arm64",
      manifest.vsockProtocol == 1,
      !manifest.id.isEmpty, !manifest.rootDisk.isEmpty, manifest.rootDisk != ".",
      manifest.rootDisk != "..",
      !manifest.rootDisk.contains("/"), !manifest.rootDisk.contains("\\"),
      manifest.sha256.count == 64,
      manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw RuntimeError(.invalidConfiguration, "Unsupported or unsafe appliance manifest") }
    let image = manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.rootDisk)
    try requireRegularFile(image)
    guard try digest(image) == manifest.sha256 else {
      throw RuntimeError(.invalidConfiguration, "Appliance SHA-256 mismatch")
    }
    return (image, manifest)
  }

  static func digest(_ image: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: image)
    defer { try? file.close() }
    var hasher = SHA256()
    while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func create(configuration: RuntimeConfiguration, store: StateStore) throws {
    try configuration.validate()
    let (image, manifest) = try verifiedImage(
      manifestURL: URL(fileURLWithPath: configuration.applianceManifestPath))
    guard !FileManager.default.fileExists(atPath: store.paths.runtimeDirectory.path) else {
      throw RuntimeError(
        .conflict, "Runtime files already exist; preserve them or explicitly reset")
    }
    let staging = store.paths.directory.appendingPathComponent("create-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let root = staging.appendingPathComponent("root.raw")
    try FileManager.default.copyItem(at: image, to: root)
    guard try digest(root) == manifest.sha256 else {
      throw RuntimeError(.invalidConfiguration, "Staged appliance SHA-256 mismatch")
    }
    guard chmod(root.path, 0o600) == 0 else { throw RuntimeError(.io, "Cannot secure root disk") }
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    try StateStore.growDisk(root, bytes: max(size, 12 * 1024 * 1024 * 1024))
    try StateStore.growDisk(
      staging.appendingPathComponent("data.raw"),
      bytes: configuration.dataDiskGib * 1024 * 1024 * 1024, create: true)
    if let seed = configuration.seedPath {
      let source = URL(fileURLWithPath: seed)
      try requireRegularFile(source)
      let destination = staging.appendingPathComponent("seed.iso")
      try FileManager.default.copyItem(at: source, to: destination)
      guard chmod(destination.path, 0o600) == 0 else {
        throw RuntimeError(.io, "Cannot secure seed")
      }
    }
    try FileManager.default.moveItem(at: staging, to: store.paths.runtimeDirectory)
    // A failed config commit retains disks for explicit recovery rather than erasing data.
    try store.save(configuration)
  }
}
