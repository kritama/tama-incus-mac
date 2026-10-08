import Foundation

public enum RuntimeState: String, Codable, Sendable {
  case absent, stopped, starting, ready, stopping, failed
}

public struct RuntimeProgress: Codable, Sendable {
  public let apiVersion: Int
  public let schemaVersion: Int
  public let state: RuntimeState
  public let ready: Bool
  public let operation: String?
  public let phase: String?
  public let elapsedSeconds: Int
  public let expectedReboot: Bool
  public let detail: String?
  public let lastError: String?
}

public struct RuntimeStatus: Codable, Sendable {
  public let apiVersion: Int = 1
  public let state: RuntimeState
  public let incusSocket: String
  public let lastError: String?
  public let uptimeSeconds: Int
  public enum CodingKeys: String, CodingKey {
    case apiVersion, state, incusSocket, lastError, uptimeSeconds
  }
}

public struct GuestHealth: Codable, Sendable, Equatable {
  public let protocolVersion: Int
  public let incusVersion: String
  public let apiExtensions: [String]
  public let kvm: Bool
  public init(protocolVersion: Int = 1, incusVersion: String, apiExtensions: [String], kvm: Bool) {
    self.protocolVersion = protocolVersion
    self.incusVersion = incusVersion
    self.apiExtensions = apiExtensions
    self.kvm = kvm
  }
}

public struct HostCapabilities: Codable, Sendable {
  public let platform: String
  public let architecture: String
  public let virtualization: String
  public let supported: Bool
  public let nestedVirtualization: Bool
  public let virtiofs: Bool
  public init(supported: Bool, nestedVirtualization: Bool, architecture: String = "arm64") {
    platform = "darwin"
    self.architecture = architecture
    virtualization = "apple-vz"
    self.supported = supported
    self.nestedVirtualization = nestedVirtualization
    virtiofs = supported
  }
}

public struct RuntimeCapabilities: Codable, Sendable {
  public struct Incus: Codable, Sendable {
    public let available: Bool
    public let version: String?
  }
  public struct Features: Codable, Sendable {
    public let systemContainers: Bool
    public let oci: Bool
    public let vm: Bool
    public let nestedVirtualization: Bool
    public let virtiofs: Bool
  }
  public let platform: String
  public let architecture: String
  public let virtualization: String
  public let supported: Bool
  public let incus: Incus
  public let capabilities: Features
  public init(host: HostCapabilities, health: GuestHealth?, nestingEnabled: Bool) {
    platform = host.platform
    architecture = host.architecture
    virtualization = host.virtualization
    supported = host.supported
    incus = Incus(available: health != nil, version: health?.incusVersion)
    capabilities = Features(
      systemContainers: health != nil,
      oci: health?.apiExtensions.contains("instance_oci") == true,
      vm: health != nil && health?.kvm == true && host.nestedVirtualization && nestingEnabled,
      nestedVirtualization: host.nestedVirtualization, virtiofs: host.virtiofs)
  }
}
