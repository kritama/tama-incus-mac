import Darwin
import Foundation
import Virtualization

@MainActor
public enum VirtualMachineConfiguration {
  public static func make(_ value: RuntimeConfiguration, paths: RuntimePaths) throws
    -> VZVirtualMachineConfiguration
  {
    try value.validate()
    let configuration = VZVirtualMachineConfiguration()
    guard value.cpuCount >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
      value.cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount,
      value.memoryMib * 1024 * 1024 >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
      value.memoryMib * 1024 * 1024 <= VZVirtualMachineConfiguration.maximumAllowedMemorySize
    else {
      throw RuntimeError(.invalidConfiguration, "Resources exceed Virtualization.framework limits")
    }
    configuration.cpuCount = value.cpuCount
    configuration.memorySize = value.memoryMib * 1024 * 1024
    let platform = VZGenericPlatformConfiguration()
    platform.isNestedVirtualizationEnabled =
      value.nestedVirtualization && VZGenericPlatformConfiguration.isNestedVirtualizationSupported
    configuration.platform = platform
    let boot = VZEFIBootLoader()
    if FileManager.default.fileExists(atPath: paths.efiStore.path) {
      try requireRegularFile(paths.efiStore)
      boot.variableStore = VZEFIVariableStore(url: paths.efiStore)
    } else {
      boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: paths.efiStore)
      guard chmod(paths.efiStore.path, 0o600) == 0 else {
        throw RuntimeError(.io, "Cannot secure EFI store")
      }
    }
    configuration.bootLoader = boot
    var storage: [VZStorageDeviceConfiguration] = []
    for url in [paths.rootDisk, paths.dataDisk] {
      try requireRegularFile(url)
      storage.append(
        VZVirtioBlockDeviceConfiguration(
          attachment: try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false)))
    }
    if FileManager.default.fileExists(atPath: paths.seed.path) {
      try requireRegularFile(paths.seed)
      storage.append(
        VZVirtioBlockDeviceConfiguration(
          attachment: try VZDiskImageStorageDeviceAttachment(url: paths.seed, readOnly: true)))
    }
    configuration.storageDevices = storage
    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    configuration.networkDevices = [network]
    configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    if !value.shares.isEmpty {
      let device = VZVirtioFileSystemDeviceConfiguration(tag: "tama-shares")
      let directories = Dictionary(
        uniqueKeysWithValues: value.shares.map {
          ($0.name, VZSharedDirectory(url: URL(fileURLWithPath: $0.path), readOnly: $0.readOnly))
        })
      device.share = VZMultipleDirectoryShare(directories: directories)
      configuration.directorySharingDevices = [device]
    }
    let descriptor = open(
      paths.serialLog.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw RuntimeError(.io, "Cannot open serial log") }
    let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
    serial.attachment = VZFileHandleSerialPortAttachment(
      fileHandleForReading: nil,
      fileHandleForWriting: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    configuration.serialPorts = [serial]
    try configuration.validate()
    return configuration
  }
}
