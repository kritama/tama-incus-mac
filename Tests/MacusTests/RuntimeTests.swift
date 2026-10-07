import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Macus

actor FakeVM: VirtualMachineDriver {
  var running = false
  var healthy = true
  var startCount = 0
  var stopCount = 0
  var shutdownWorks = true
  var kvm = true
  func capabilities() async -> HostCapabilities {
    HostCapabilities(supported: true, nestedVirtualization: true)
  }
  func start(configuration: RuntimeConfiguration, paths: RuntimePaths) async throws {
    running = true
    startCount += 1
  }
  func requestStop() async throws {
    if shutdownWorks { running = false }
    stopCount += 1
  }
  func forceStop() async throws {
    running = false
    stopCount += 1
  }
  func isRunning() async -> Bool { running }
  func openStream(port: UInt32) async throws -> GuestStream {
    throw RuntimeError(.unavailable, "No stream in fake")
  }
  func health() async throws -> GuestHealth {
    guard healthy, running else { throw RuntimeError(.unavailable, "Guest not healthy") }
    return GuestHealth(incusVersion: "test", apiExtensions: ["instance_oci"], kvm: kvm)
  }
  func setHealthy(_ value: Bool) { healthy = value }
  func setRunning(_ value: Bool) { running = value }
  func setShutdownWorks(_ value: Bool) { shutdownWorks = value }
}

struct Fixture {
  let paths: RuntimePaths
  let configuration: RuntimeConfiguration
  init() throws {
    let root = URL(fileURLWithPath: "/private/tmp/macus-\(UUID())")
    paths = RuntimePaths(directory: root)
    try paths.prepare()
    try FileManager.default.createDirectory(
      at: paths.runtimeDirectory, withIntermediateDirectories: false)
    try Data([1, 2, 3]).write(to: paths.rootDisk)
    try StateStore.growDisk(paths.dataDisk, bytes: 1024 * 1024 * 1024, create: true)
    var configuration = RuntimeConfiguration(
      applianceManifestPath: root.appendingPathComponent("manifest.json").path)
    configuration.dataDiskGib = 1
    configuration.readinessTimeoutSeconds = 1
    configuration.shutdownTimeoutSeconds = 1
    self.configuration = configuration
    try StateStore(paths: paths).save(configuration)
  }
  func clean() { try? FileManager.default.removeItem(at: paths.directory) }
}

@Test func lifecycleAndRecovery() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = FakeVM()
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  #expect(await service.status().state == .stopped)
  #expect(try await service.start().state == .ready)
  #expect(try await service.start().state == .ready)
  #expect(await driver.startCount == 1)
  #expect(await service.capabilities().capabilities.vm)
  #expect(try await service.stop().state == .stopped)
  #expect(try await service.restart().state == .ready)
  await driver.setRunning(false)
  #expect(await service.status().state == .failed)
  #expect(!(await service.capabilities().incus.available))
  let recovered = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  #expect(await recovered.status().state == .stopped)
}

@Test func reentrancyCannotDeleteStartingRuntime() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = FakeVM()
  await driver.setHealthy(false)
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  let start = Task { try await service.start() }
  for _ in 0..<100 {
    if await driver.running { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  await #expect(throws: RuntimeError(.conflict, "A runtime mutation is already in progress")) {
    try await service.delete(confirm: true)
  }
  #expect(FileManager.default.fileExists(atPath: fixture.paths.dataDisk.path))
  await driver.setHealthy(true)
  #expect(try await start.value.state == .ready)
}

@Test func timeoutNeverSilentlyForcesStop() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = FakeVM()
  await driver.setShutdownWorks(false)
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  _ = try await service.start()
  await #expect(throws: RuntimeError.self) { try await service.stop() }
  #expect(await driver.running)
  #expect(await driver.stopCount == 1)
  #expect(await service.status().lastError != nil)
  #expect(try await service.stop(force: true).state == .stopped)
}

@Test func updateAndDeletionSafety() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let service = try RuntimeService(driver: FakeVM(), store: StateStore(paths: fixture.paths))
  var configuration = fixture.configuration
  configuration.dataDiskGib = 0
  await #expect(throws: RuntimeError.self) { try await service.update(configuration) }
  #expect(try await service.config() == fixture.configuration)
  await #expect(throws: RuntimeError.self) { try await service.delete(confirm: false) }
  _ = try await service.start()
  await #expect(throws: RuntimeError.self) { try await service.delete(confirm: true) }
  _ = try await service.stop()
  #expect(try await service.delete(confirm: true).state == .absent)
}

@Test func liveCapabilitiesRequireEvidence() {
  let host = HostCapabilities(supported: true, nestedVirtualization: true)
  let unknown = RuntimeCapabilities(host: host, health: nil, nestingEnabled: true)
  #expect(
    !unknown.capabilities.systemContainers && !unknown.capabilities.oci && !unknown.capabilities.vm)
  let guest = GuestHealth(incusVersion: "6.0", apiExtensions: [], kvm: false)
  let live = RuntimeCapabilities(host: host, health: guest, nestingEnabled: true)
  #expect(live.capabilities.systemContainers && !live.capabilities.oci && !live.capabilities.vm)
}

@Test func configurationRejectsUnsafeInputs() throws {
  var configuration = RuntimeConfiguration(applianceManifestPath: "/tmp/manifest.json")
  configuration.shares = [DirectoryShare(name: "../escape", path: "/tmp")]
  #expect(throws: RuntimeError.self) { try configuration.validate() }
  configuration.shares = []
  configuration.memoryMib = UInt64.max
  #expect(throws: RuntimeError.self) { try configuration.validate() }
  configuration.memoryMib = 4096
  configuration.applianceManifestPath = "relative"
  #expect(throws: RuntimeError.self) { try configuration.validate() }
}

@Test func growthPreservesBytesAndRefusesShrink() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let file = try FileHandle(forWritingTo: fixture.paths.dataDisk)
  try file.write(contentsOf: Data("persisted".utf8))
  try file.close()
  try StateStore.growDisk(fixture.paths.dataDisk, bytes: 2 * 1024 * 1024 * 1024)
  #expect(throws: RuntimeError.self) { try StateStore.growDisk(fixture.paths.dataDisk, bytes: 100) }
  let reader = try FileHandle(forReadingFrom: fixture.paths.dataDisk)
  defer { try? reader.close() }
  #expect(try reader.read(upToCount: 9) == Data("persisted".utf8))
}

@Test func symlinkAndDuplicateLockRejected() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let lock = try StateLock(paths: fixture.paths)
  #expect(throws: RuntimeError.self) { try StateLock(paths: fixture.paths) }
  withExtendedLifetime(lock) {}
  let link = fixture.paths.directory.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.paths.directory)
  #expect(throws: RuntimeError.self) { try RuntimePaths(directory: link).prepare() }
}

@Test func manifestDigestAndTraversal() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let image = fixture.paths.directory.appendingPathComponent("image.raw")
  let data = Data("linux-disk".utf8)
  try data.write(to: image)
  let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  let manifestURL = URL(fileURLWithPath: fixture.configuration.applianceManifestPath)
  func manifest(_ disk: String, _ hash: String) throws {
    let manifest = ApplianceManifest(
      schemaVersion: 1, id: "test", architecture: "arm64", rootDisk: disk, sha256: hash,
      vsockProtocol: 1)
    try JSON.encoder().encode(manifest).write(to: manifestURL)
  }
  try manifest("image.raw", digest)
  #expect(try GuestImageManager.verify(manifestURL: manifestURL) == image)
  try manifest("../image.raw", digest)
  #expect(throws: RuntimeError.self) { try GuestImageManager.verify(manifestURL: manifestURL) }
  try manifest("image.raw", String(repeating: "0", count: 64))
  #expect(throws: RuntimeError.self) { try GuestImageManager.verify(manifestURL: manifestURL) }
}

@Test func controlRoutesValidatePayloadAndNamespace() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let service = try RuntimeService(driver: FakeVM(), store: StateStore(paths: fixture.paths))
  let routes = RuntimeRoutes(service: service)
  #expect(
    await routes.handle(HTTPRequest(method: "GET", path: "/v1/runtime/status", body: Data())).status
      == 200)
  #expect(
    await routes.handle(HTTPRequest(method: "POST", path: "/v1/incus/instances", body: Data()))
      .status == 404)
  #expect(
    await routes.handle(HTTPRequest(method: "DELETE", path: "/v1/runtime", body: Data("{}".utf8)))
      .status == 400)
  #expect(FileManager.default.fileExists(atPath: fixture.paths.dataDisk.path))
}

@Test func explicitForceStopCancelsBootWait() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = FakeVM()
  await driver.setHealthy(false)
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  let start = Task { try await service.start() }
  for _ in 0..<100 {
    if await driver.running { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(try await service.stop(force: true).state == .stopped)
  #expect(!(await driver.running))
  _ = await start.result
  #expect(await service.status().state == .stopped)
}

@Test func readinessTimeoutKeepsDiskAndRevokesCapabilities() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = FakeVM()
  await driver.setHealthy(false)
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  await #expect(throws: RuntimeError.self) { try await service.start() }
  #expect(await service.status().state == .failed)
  #expect(await driver.running)
  #expect(!(await service.capabilities().incus.available))
  #expect(FileManager.default.fileExists(atPath: fixture.paths.dataDisk.path))
  _ = try await service.stop(force: true)
}

@Test func omittedShareModeDefaultsToReadOnly() throws {
  let share = try JSON.decoder().decode(
    DirectoryShare.self, from: Data(#"{"name":"project","path":"/tmp"}"#.utf8))
  #expect(share.readOnly)
}

@Test func createVerifiedRuntimeAndRepeatWithoutReplacingData() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let store = StateStore(paths: fixture.paths)
  try store.delete()
  let image = fixture.paths.directory.appendingPathComponent("image.raw")
  let content = Data("appliance".utf8)
  try content.write(to: image)
  let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
  let manifest = ApplianceManifest(
    schemaVersion: 1, id: "test", architecture: "arm64", rootDisk: "image.raw", sha256: digest,
    vsockProtocol: 1)
  try JSON.encoder().encode(manifest).write(
    to: URL(fileURLWithPath: fixture.configuration.applianceManifestPath))
  let service = try RuntimeService(driver: FakeVM(), store: store)
  #expect(try await service.create(fixture.configuration).state == .stopped)
  let disk = try FileHandle(forWritingTo: fixture.paths.dataDisk)
  try disk.write(contentsOf: Data("kept".utf8))
  try disk.close()
  #expect(try await service.create(fixture.configuration).state == .stopped)
  let reader = try FileHandle(forReadingFrom: fixture.paths.dataDisk)
  defer { try? reader.close() }
  #expect(try reader.read(upToCount: 4) == Data("kept".utf8))
  #expect(try store.load() == fixture.configuration)
}

@Test func startRevalidatesDeadGuestWithoutStatusPolling() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = FakeVM()
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  _ = try await service.start()
  await driver.setRunning(false)
  #expect(try await service.start().state == .ready)
  #expect(await driver.startCount == 2)
}

@Test func repeatedStartRevokesUnhealthyRunningGuest() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let driver = FakeVM()
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  _ = try await service.start()
  await driver.setHealthy(false)
  await #expect(
    throws: RuntimeError(.conflict, "VM is running but unhealthy; stop before recovery")
  ) {
    try await service.start()
  }
  #expect(await service.status().state == .failed)
  #expect(!(await service.capabilities().incus.available))
  #expect(await driver.startCount == 1)
  #expect(await driver.running)
}

@Test func configurationJSONRequiresCompleteNonoptionalFields() async throws {
  let minimal = Data(#"{"appliance_manifest_path":"/tmp/manifest.json"}"#.utf8)
  #expect(throws: DecodingError.self) {
    try JSON.decoder().decode(RuntimeConfiguration.self, from: minimal)
  }
  let fixture = try Fixture()
  defer { fixture.clean() }
  let service = try RuntimeService(driver: FakeVM(), store: StateStore(paths: fixture.paths))
  let routes = RuntimeRoutes(service: service)
  let response = await routes.handle(
    HTTPRequest(method: "POST", path: "/v1/runtime/create", body: minimal))
  #expect(response.status == 400)
  var custom = fixture.configuration
  custom.cpuCount = 7
  custom.memoryMib = 8192
  custom.nestedVirtualization = false
  custom.seedPath = nil
  #expect(
    try JSON.decoder().decode(RuntimeConfiguration.self, from: JSON.encoder().encode(custom))
      == custom)
}

@Test(arguments: [false, true]) func interruptedConfirmedResetCompletesBeforeLoadingConfiguration(
  configurationRemoved: Bool
) throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let store = StateStore(paths: fixture.paths)
  try Data("external image".utf8).write(
    to: URL(fileURLWithPath: fixture.configuration.applianceManifestPath))
  try Data("diagnostics".utf8).write(to: fixture.paths.serialLog)
  try store.beginReset()
  try FileManager.default.removeItem(at: fixture.paths.runtimeDirectory)
  if configurationRemoved { try FileManager.default.removeItem(at: fixture.paths.config) }
  #expect(try store.load() == nil)
  #expect(!FileManager.default.fileExists(atPath: fixture.paths.config.path))
  #expect(!FileManager.default.fileExists(atPath: fixture.paths.resetIntent.path))
  #expect(FileManager.default.fileExists(atPath: fixture.configuration.applianceManifestPath))
  #expect(FileManager.default.fileExists(atPath: fixture.paths.serialLog.path))
  #expect(try store.load() == nil)
}

@Test func invalidResetIntentAndUnconfirmedIncompleteStatePreserveData() throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let store = StateStore(paths: fixture.paths)
  try Data("unconfirmed".utf8).write(to: fixture.paths.resetIntent)
  #expect(throws: RuntimeError.self) { try store.load() }
  #expect(throws: RuntimeError.self) { try store.delete() }
  #expect(FileManager.default.fileExists(atPath: fixture.paths.dataDisk.path))
  try FileManager.default.removeItem(at: fixture.paths.resetIntent)
  try FileManager.default.removeItem(at: fixture.paths.rootDisk)
  #expect(throws: RuntimeError.self) { try store.load() }
  #expect(FileManager.default.fileExists(atPath: fixture.paths.config.path))
  #expect(FileManager.default.fileExists(atPath: fixture.paths.dataDisk.path))
}
