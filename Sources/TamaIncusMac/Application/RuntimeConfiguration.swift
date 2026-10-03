import Foundation

public struct DirectoryShare: Codable, Sendable, Equatable {
  public var name: String
  public var path: String
  public var readOnly: Bool = true
  public init(name: String, path: String, readOnly: Bool = true) {
    self.name = name
    self.path = path
    self.readOnly = readOnly
  }
}

public struct RuntimeConfiguration: Codable, Sendable, Equatable {
  public var schemaVersion: Int = 1
  public var cpuCount: Int = 4
  public var memoryMib: UInt64 = 4096
  public var dataDiskGib: UInt64 = 32
  public var applianceManifestPath: String
  public var seedPath: String?
  public var nestedVirtualization: Bool = true
  public var shares: [DirectoryShare] = []
  public var readinessTimeoutSeconds: Int = 600
  public var shutdownTimeoutSeconds: Int = 60

  public init(applianceManifestPath: String, seedPath: String? = nil) {
    self.applianceManifestPath = applianceManifestPath
    self.seedPath = seedPath
  }

  public func validate() throws {
    guard schemaVersion == 1, (1...64).contains(cpuCount),
      (512...262144).contains(memoryMib), (1...16384).contains(dataDiskGib),
      (1...1800).contains(readinessTimeoutSeconds), (1...300).contains(shutdownTimeoutSeconds)
    else { throw RuntimeError(.invalidConfiguration, "Unsupported schema or resource limits") }
    guard applianceManifestPath.hasPrefix("/"), seedPath == nil || seedPath!.hasPrefix("/") else {
      throw RuntimeError(.invalidConfiguration, "Image manifest and seed paths must be absolute")
    }
    var names = Set<String>()
    for share in shares {
      guard !share.name.isEmpty, share.name.count <= 36,
        share.name.utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            || $0 == 95
        }),
        names.insert(share.name).inserted, share.path.hasPrefix("/"), share.path != "/"
      else { throw RuntimeError(.invalidConfiguration, "Invalid or duplicate share name/path") }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: share.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw RuntimeError(.invalidConfiguration, "Share directory does not exist: \(share.path)")
      }
    }
  }
}
