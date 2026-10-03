import Virtualization

@MainActor
public enum CapabilityDetector {
  public static func detect() -> HostCapabilities {
    #if arch(arm64)
      HostCapabilities(
        supported: VZVirtualMachine.isSupported,
        nestedVirtualization: VZGenericPlatformConfiguration.isNestedVirtualizationSupported)
    #else
      HostCapabilities(supported: false, nestedVirtualization: false, architecture: "x86_64")
    #endif
  }
}
