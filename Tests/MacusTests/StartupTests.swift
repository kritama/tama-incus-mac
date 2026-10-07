import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Macus

@Test func startupBudgetIsSharedAndCancellationDoesNotResetIt() throws {
  let start = ContinuousClock.now
  let budget = StartupBudget(seconds: 10, now: start)
  let later = start.advanced(by: .seconds(4))
  #expect(try budget.remainingSeconds(at: later) == 6)
  #expect(try budget.remainingSeconds(at: later.advanced(by: .seconds(5))) == 1)
  #expect(throws: RuntimeError.self) {
    try budget.remainingSeconds(at: start.advanced(by: .seconds(10)))
  }
  let retained = budget
  #expect(retained.deadline == budget.deadline)
  #expect(retained.started == budget.started)
}

@Test func progressRendererDoesNotInventPercentagesOrReadiness() {
  var plain = ProgressRenderer(rendering: .plain)
  let now = ContinuousClock.now
  let unknown = StartupProgressEvent(
    operationID: "op", stage: .acquisition, state: .active, elapsedSeconds: 3, completedBytes: 12,
    totalBytes: nil, detail: nil)
  let line = plain.render(unknown, now: now) ?? ""
  #expect(line.contains("12 bytes"))
  #expect(!line.contains("%"))
  #expect(!line.contains("\u{1B}"))
  let launch = StartupProgressEvent(
    operationID: "op", stage: .serviceActivation, state: .active, elapsedSeconds: 1,
    detail: "launchd")
  let service = plain.render(launch, now: now) ?? ""
  #expect(service.contains("service_activation: active"))
  #expect(!service.contains("ready"))
  let dumb = ProgressRenderer.resolve(
    selection: .auto, stderrIsTTY: false, term: "dumb", json: false)
  #expect(dumb == .plain)
  let json = ProgressRenderer.resolve(
    selection: .auto, stderrIsTTY: true, term: "xterm-256color", json: true)
  #expect(json == .plain)
  #expect(
    ProgressRenderer.resolve(selection: .none, stderrIsTTY: true, term: "xterm", json: false)
      == .none)
}

@Test func animatedProgressUsesPseudoTerminalAndRestoresCursor() throws {
  var primary: Int32 = 0
  var replica: Int32 = 0
  #expect(openpty(&primary, &replica, nil, nil, nil) == 0)
  defer {
    close(primary)
    close(replica)
  }
  #expect(isatty(replica) == 1)
  let rendering = ProgressRenderer.resolve(
    selection: .auto, stderrIsTTY: true, term: "xterm-256color", json: false)
  #expect(rendering == .animated)
  var renderer = ProgressRenderer(rendering: rendering)
  let text =
    renderer.render(
      StartupProgressEvent(
        operationID: "op", stage: .acquisition, state: .active, elapsedSeconds: 1,
        completedBytes: 4,
        totalBytes: 8),
      now: .now) ?? ""
  let cleanup = renderer.cleanup()
  #expect(text.contains("\u{1B}[?25l"))
  #expect(text.contains("50%"))
  #expect(cleanup.contains("\u{1B}[?25h"))
  let payload = Data((text + cleanup).utf8)
  let written = payload.withUnsafeBytes { Darwin.write(replica, $0.baseAddress, payload.count) }
  #expect(written == payload.count)
  var buffer = [UInt8](repeating: 0, count: 512)
  let readCount = buffer.withUnsafeMutableBytes { Darwin.read(primary, $0.baseAddress, $0.count) }
  #expect(readCount > 0)
  let captured = String(decoding: buffer.prefix(readCount), as: UTF8.self)
  #expect(captured.contains("\u{1B}[?25l"))
  #expect(captured.contains("\u{1B}[?25h"))
}

@Test func guestObservationsIgnoreUnknownAndKeepCurrentBootSignal() {
  #expect(GuestObservationParser.parse(line: "MACUS_OBSERVATION v2 stage=packages") == nil)
  #expect(GuestObservationParser.parse(line: "MACUS_OBSERVATION v1 stage=mystery") == nil)
  #expect(GuestObservationParser.parse(line: "not a marker") == nil)
  let reboot = GuestObservationParser.parse(
    line: "MACUS_OBSERVATION v1 stage=kernel_transition state=expected_reboot")
  #expect(reboot?.expectsKernelReboot == true)
  #expect(
    GuestObservationParser.parse(line: "TAMA_ZFS_KERNEL_REBOOT_REQUIRED")?.expectsKernelReboot
      == true)
  let failed = GuestObservationParser.parse(
    line: "MACUS_OBSERVATION v1 stage=failed code=qualified_revision_unavailable")
  #expect(failed?.failed == true)
  #expect(failed?.expectsKernelReboot == false)
}

@Test func archiveReaderRejectsUnsafeMembersAndTruncation() throws {
  let root = URL(fileURLWithPath: "/tmp/macus-tar-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let payload = Data("disk".utf8)
  let good = root.appendingPathComponent("good.raw")
  try TarArchive.extract(
    tar: tarArchive(name: "disk.raw", contents: payload), member: "disk.raw", expectedBytes: 4,
    to: good)
  #expect(try Data(contentsOf: good) == payload)

  let outside = root.appendingPathComponent("outside")
  try Data("keep".utf8).write(to: outside)
  for archive in [
    tarArchive(name: "../disk.raw", contents: payload),
    tarArchive(name: "disk.raw", contents: payload, type: UInt8(ascii: "2")),
    tarMember(name: "disk.raw", contents: payload)
      + tarMember(name: "extra", contents: Data("x".utf8))
      + Data(count: 1024),
    Data(tarArchive(name: "disk.raw", contents: payload).prefix(100)),
  ] {
    let destination = root.appendingPathComponent(UUID().uuidString)
    #expect(throws: RuntimeError.self) {
      try TarArchive.extract(tar: archive, member: "disk.raw", expectedBytes: 4, to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }
  #expect(try Data(contentsOf: outside) == Data("keep".utf8))
  let oversize = tarArchive(name: "disk.raw", contents: payload, declaredSize: 9_000_000)
  #expect(throws: RuntimeError.self) {
    try TarArchive.extract(
      tar: oversize, member: "disk.raw", expectedBytes: 4,
      to: root.appendingPathComponent("oversize"))
  }
}

@Test func startUsageFailsBeforeCreatingState() async throws {
  let missing = URL(fileURLWithPath: "/tmp/macus-start-\(UUID().uuidString.prefix(8))")
  let capture = StartCapture()
  let status = await MacusCLI.run(
    arguments: ["--state-dir", missing.path, "start", "--progress", "sideways"],
    streams: capture.streams)
  #expect(status == 2)
  #expect(!FileManager.default.fileExists(atPath: missing.path))
  let help = await MacusCLI.run(arguments: ["--help"], streams: capture.streams)
  #expect(help == 0)
  let text = capture.output
  for token in ["start", "1800", "--progress", "client setup", "650", "10", "Homebrew"] {
    #expect(text.contains(token))
  }
}

@Test func missingPrerequisiteDoesNotDownloadOrRegister() async throws {
  let missing = URL(fileURLWithPath: "/tmp/macus-pre-\(UUID().uuidString.prefix(8))")
  let downloader = RecordingDownloader()
  let launch = FakeLaunchControl()
  let capture = StartCapture()
  let status = await MacusCLI.run(
    arguments: ["--state-dir", missing.path, "--json", "start"],
    environment: ["PATH": "/usr/bin:/bin", "MACUS_BREW_FALLBACK": "0"],
    streams: capture.streams,
    overrides: StartupOverrides(
      hasEntitlement: { true },
      downloader: downloader,
      launchControl: launch,
      installSignals: false))
  #expect(status == 1)
  #expect(downloader.calls == 0)
  #expect(launch.bootstrapped.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: missing.path))
  #expect(capture.error.contains("brew.sh"))
}

@Test func currentBootRebootIsBoundedAcrossDaemonRestartAndForceStop() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  var configuration = fixture.configuration
  configuration.readinessTimeoutSeconds = 5
  try StateStore(paths: fixture.paths).save(configuration)
  try RebootAllowanceStore.ensureAvailable(paths: fixture.paths, catalogID: "test")
  let driver = FakeVM()
  await driver.setHealthy(false)
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  let start = Task { try await service.start() }
  for _ in 0..<100 {
    if await driver.running { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  try Data("MACUS_OBSERVATION v1 stage=kernel_transition state=expected_reboot\n".utf8).write(
    to: fixture.paths.serialLog)
  await driver.setRunning(false)
  for _ in 0..<40 {
    if await driver.startCount >= 2 { break }
    try await Task.sleep(for: .milliseconds(50))
  }
  await driver.setHealthy(true)
  #expect(try await start.value.state == .ready)
  #expect(await driver.startCount == 2)
  #expect(try RebootAllowanceStore.state(paths: fixture.paths) == "consumed")

  let restarted = FakeVM()
  await restarted.setHealthy(false)
  let again = try RuntimeService(driver: restarted, store: StateStore(paths: fixture.paths))
  let second = Task { try await again.start() }
  for _ in 0..<100 {
    if await restarted.running { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  let handle = try FileHandle(forWritingTo: fixture.paths.serialLog)
  try handle.seekToEnd()
  try handle.write(
    contentsOf: Data("MACUS_OBSERVATION v1 stage=kernel_transition state=expected_reboot\n".utf8))
  try handle.close()
  await restarted.setRunning(false)
  await #expect(throws: RuntimeError.self) { try await second.value }
  #expect(await restarted.startCount == 1)
  #expect(try RebootAllowanceStore.state(paths: fixture.paths) == "consumed")
  #expect(FileManager.default.fileExists(atPath: fixture.paths.dataDisk.path))
}

@Test func staleRebootMarkerDoesNotRestart() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try Data("TAMA_ZFS_KERNEL_REBOOT_REQUIRED\n".utf8).write(to: fixture.paths.serialLog)
  try RebootAllowanceStore.ensureAvailable(paths: fixture.paths, catalogID: "test")
  let driver = FakeVM()
  await driver.setHealthy(false)
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  let start = Task { try await service.start() }
  for _ in 0..<100 {
    if await driver.running { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  await driver.setRunning(false)
  await #expect(throws: RuntimeError.self) { try await start.value }
  #expect(await driver.startCount == 1)
  #expect(try RebootAllowanceStore.state(paths: fixture.paths) == "available")
  #expect(FileManager.default.fileExists(atPath: fixture.paths.dataDisk.path))
}

@Test func forceStopDuringExpectedRestartDoesNotRaceAnotherBoot() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  try RebootAllowanceStore.ensureAvailable(paths: fixture.paths, catalogID: "test")
  let driver = FakeVM()
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  let start = Task { try await service.start() }
  for _ in 0..<100 {
    if await driver.running { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  try Data("MACUS_OBSERVATION v1 stage=kernel_transition state=expected_reboot\n".utf8).write(
    to: fixture.paths.serialLog)
  await driver.setRunning(false)
  #expect(try await service.stop(force: true).state == .stopped)
  _ = await start.result
  let count = await driver.startCount
  try await Task.sleep(for: .milliseconds(200))
  #expect(await driver.startCount == count)
  #expect(await service.status().state == .stopped)
  #expect(FileManager.default.fileExists(atPath: fixture.paths.dataDisk.path))
}

@Test func invalidStartBudgetDoesNotBootOrSaveConfig() async throws {
  let fixture = try Fixture()
  defer { fixture.clean() }
  let before = try Data(contentsOf: fixture.paths.config)
  let driver = FakeVM()
  let service = try RuntimeService(driver: driver, store: StateStore(paths: fixture.paths))
  let routes = RuntimeRoutes(service: service)
  let invalid = await routes.handle(
    HTTPRequest(
      method: "POST", path: "/v1/runtime/start", body: Data("{\"remaining_seconds\":0}".utf8)))
  #expect(invalid.status == 400)
  #expect(await driver.startCount == 0)
  #expect(try Data(contentsOf: fixture.paths.config) == before)
  let empty = await routes.handle(
    HTTPRequest(method: "POST", path: "/v1/runtime/start", body: Data()))
  #expect(empty.status == 200)
  #expect(try Data(contentsOf: fixture.paths.config) == before)
}

@Test func mismatchedDigestAndCorruptCacheDoNotReplaceRuntimeData() async throws {
  let root = URL(fileURLWithPath: "/tmp/macus-cache-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let sentinel = root.appendingPathComponent("runtime/data.raw")
  try FileManager.default.createDirectory(
    at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("keep".utf8).write(to: sentinel)
  var entry = ApplianceCatalogEntry.current
  entry.archiveBytes = 4
  entry.archiveSHA512 = String(repeating: "ab", count: 64)
  entry.rawBytes = 4
  entry.rawSHA256 = String(repeating: "cd", count: 32)
  let downloader = BytesDownloader(bytes: Data("nope".utf8))
  let acquisition = ApplianceAcquisition(downloader: downloader)
  let budget = StartupBudget(seconds: 5, now: .now)
  await #expect(throws: RuntimeError.self) {
    _ = try await acquisition.materialize(
      entry: entry, directory: root, budget: budget, now: { .now }, onBytes: { _, _ in })
  }
  #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
  let cache = root.appendingPathComponent("appliance-cache").appendingPathComponent(entry.id)
  try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  try Data("corrupt".utf8).write(to: cache.appendingPathComponent("root.raw"))
  await #expect(throws: RuntimeError.self) {
    _ = try await acquisition.materialize(
      entry: entry, directory: root, budget: budget, now: { .now }, onBytes: { _, _ in })
  }
  #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
  #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("root.raw").path))
}

@Test func seedPreparationUsesEmbeddedPayloadAndCleansFailures() async throws {
  let text = try SeedPreparation.userData()
  let bootstrap = try EmbeddedGuestPayload.text("bootstrap.sh")
  #expect(text.contains("path: /usr/local/libexec/tama-bootstrap.sh"))
  #expect(text.contains(bootstrap.split(separator: "\n").first.map(String.init) ?? "missing"))
  #expect(text.contains("disable_root: true"))
  let root = URL(fileURLWithPath: "/tmp/macus-seed-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let failing = FailingRunner()
  await #expect(throws: RuntimeError.self) {
    _ = try await SeedPreparation.prepare(
      entry: .current, cache: root, runner: failing, timeout: 2, environment: [:])
  }
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("seed.iso").path))
  let manifest = try await SeedPreparation.prepare(
    entry: .current, cache: root, runner: ProcessCommandRunner(), timeout: 30, environment: [:])
  #expect(FileManager.default.fileExists(atPath: manifest.path))
  let again = try await SeedPreparation.prepare(
    entry: .current, cache: root, runner: failing, timeout: 2, environment: [:])
  #expect(again == manifest)
  let iso = root.appendingPathComponent("seed.iso")
  let attributes = try FileManager.default.attributesOfItem(atPath: iso.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
}

@Test func progressStaysUnreadUntilLiveHealth() async throws {
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
  let progress = await service.progress()
  #expect(!progress.ready)
  #expect(progress.state == .starting)
  let routes = RuntimeRoutes(service: service)
  let response = await routes.handle(
    HTTPRequest(method: "GET", path: "/v1/runtime/progress", body: Data()))
  #expect(response.status == 200)
  let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
  #expect(object?["ready"] as? Bool == false)
  await driver.setHealthy(true)
  _ = try await start.value
}

struct StartCapture: Sendable {
  private let outputBox = LockedText()
  private let errorBox = LockedText()
  var streams: MacusStreams {
    MacusStreams(
      writeOutput: { self.outputBox.append($0) },
      writeError: { self.errorBox.append($0) })
  }
  var output: String { outputBox.text }
  var error: String { errorBox.text }
}

private final class LockedText: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = ""
  func append(_ text: String) {
    lock.lock()
    storage += text
    lock.unlock()
  }
  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private struct BytesDownloader: ApplianceDownloader {
  var bytes: Data
  func download(
    url: URL, to destination: URL, maximumBytes: Int64, deadline: ContinuousClock.Instant,
    onBytes: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws {
    try bytes.write(to: destination)
    onBytes(Int64(bytes.count), nil)
  }
}

private struct FailingRunner: LocalCommandRunner {
  func run(
    executable: String, arguments: [String], environment: [String: String], timeout: Int
  ) async throws -> LocalCommandResult {
    LocalCommandResult(status: 1, stdout: Data(), stderr: Data("hdiutil failed".utf8))
  }
}

final class RecordingDownloader: ApplianceDownloader, @unchecked Sendable {
  var calls = 0
  func download(
    url: URL, to destination: URL, maximumBytes: Int64, deadline: ContinuousClock.Instant,
    onBytes: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws {
    calls += 1
  }
}

final class FakeLaunchControl: LaunchControl, @unchecked Sendable {
  var bootstrapped: [String] = []
  var jobs: [String: LaunchJob] = [:]
  func printJob(label: String, timeout: Int) async throws -> LaunchJob? { jobs[label] }
  func bootstrap(plist: URL, timeout: Int) async throws { bootstrapped.append(plist.path) }
  func plist(at url: URL) throws -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
      as? [String: Any]
  }
}

private func tarArchive(
  name: String, contents: Data, type: UInt8 = UInt8(ascii: "0"), declaredSize: Int? = nil
) -> Data {
  tarMember(name: name, contents: contents, type: type, declaredSize: declaredSize)
    + Data(count: 1024)
}

private func tarMember(
  name: String, contents: Data, type: UInt8 = UInt8(ascii: "0"), declaredSize: Int? = nil
) -> Data {
  var header = Data(count: 512)
  let nameBytes = Array(name.utf8)
  header.replaceSubrange(0..<nameBytes.count, with: nameBytes)
  let size = declaredSize ?? contents.count
  let sizeField = String(format: "%011o", size).utf8
  header.replaceSubrange(124..<(124 + sizeField.count), with: sizeField)
  header[156] = type
  let magic = Array("ustar".utf8)
  header.replaceSubrange(257..<(257 + magic.count), with: magic)
  for index in 148..<156 { header[index] = 32 }
  let sum = header.reduce(0) { $0 + Int($1) }
  let checksum = String(format: "%06o", sum).utf8
  header.replaceSubrange(148..<(148 + checksum.count), with: checksum)
  header[154] = 0
  header[155] = 32
  var archive = header
  if declaredSize == nil {
    archive.append(contents)
    archive.append(Data(count: (512 - (contents.count % 512)) % 512))
  }
  return archive
}
