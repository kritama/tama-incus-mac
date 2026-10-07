import Darwin
import Foundation

struct StartupOverrides: Sendable {
  var capabilities: (@Sendable () async -> HostCapabilities)?
  var hasEntitlement: (@Sendable () -> Bool)?
  var downloader: (any ApplianceDownloader)?
  var launchControl: (any LaunchControl)?
  var executablePath: (@Sendable () -> String)?
  var now: (@Sendable () -> ContinuousClock.Instant)?
  var homeDirectory: URL?
  var launchAgentsDirectory: URL?
  var catalog: ApplianceCatalogEntry?
  var stderrIsTTY: Bool?
  var term: String?
  var installSignals = true
  var uid: uid_t?
  var runner: (any LocalCommandRunner)?
}

func runStart(
  directory: URL, remote: String, setDefault: Bool, incusOverride: String?,
  progress: ProgressSelection,
  timeout: Int, json: Bool, environment: [String: String], transport: any LocalHTTPTransport,
  runner: any LocalCommandRunner, streams: MacusStreams, overrides: StartupOverrides
) async throws {
  let rendering = ProgressRenderer.resolve(
    selection: progress, stderrIsTTY: overrides.stderrIsTTY ?? (isatty(STDERR_FILENO) == 1),
    term: overrides.term ?? environment["TERM"], json: json)
  let sink = TerminalProgressSink(rendering: rendering) { text in streams.writeError(text) }
  defer { streams.writeError(sink.cleanup()) }
  let home = overrides.homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  let dependencies = StartupDependencies(
    transport: transport,
    runner: overrides.runner ?? runner,
    downloader: overrides.downloader ?? URLSessionApplianceDownloader(),
    launchControl: overrides.launchControl
      ?? ProcessLaunchControl(
        runner: runner, environment: environment, uid: overrides.uid ?? getuid()),
    capabilities: overrides.capabilities ?? { await MainActor.run { CapabilityDetector.detect() } },
    hasEntitlement: overrides.hasEntitlement ?? { currentProcessHasVirtualizationEntitlement() },
    executablePath: overrides.executablePath ?? { currentExecutablePath() },
    now: overrides.now ?? { ContinuousClock.now },
    homeDirectory: home,
    launchAgentsDirectory: overrides.launchAgentsDirectory
      ?? home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
    uid: overrides.uid ?? getuid(),
    catalog: overrides.catalog ?? .current,
    sink: sink)
  let request = StartupRequest(
    stateDirectory: directory, remote: remote, setDefault: setDefault, incusOverride: incusOverride,
    timeout: timeout, environment: environment)
  let task = Task { try await StartupCoordinator(dependencies: dependencies).run(request) }
  let signals = overrides.installSignals ? SignalCancellation(task: task) : nil
  defer { signals?.cancel() }
  let result = try await task.value
  if json {
    streams.writeOutput(try jsonText(resultObject(result)))
  } else {
    streams.writeOutput(humanResult(result))
  }
}

private func resultObject(_ result: StartupResult) -> [String: Any] {
  var object: [String: Any] = [
    "connected": result.connected,
    "incus": result.incus,
    "installed": result.installed,
    "next_commands": result.nextCommands,
    "ready": result.ready,
    "remote": result.remote,
    "service_ownership": result.serviceOwnership,
    "state_directory": result.stateDirectory,
  ]
  if let label = result.serviceLabel { object["service_label"] = label }
  if let guidance = result.pathGuidance { object["path_guidance"] = guidance }
  if let capabilities = result.capabilities,
    let data = try? JSON.encoder().encode(capabilities),
    let decoded = try? JSONSerialization.jsonObject(with: data)
  {
    object["capabilities"] = decoded
  }
  return object
}

private func humanResult(_ result: StartupResult) -> String {
  var lines = [
    "macus start ready",
    "state: \(result.stateDirectory)",
    "remote: \(result.remote)",
    "incus: \(result.incus)",
    "service: \(result.serviceOwnership)",
  ]
  if let label = result.serviceLabel { lines.append("service label: \(label)") }
  if result.serviceOwnership == "foreground" {
    lines.append("foreground ownership: closing that terminal still stops the daemon")
  }
  if let capabilities = result.capabilities {
    lines.append("system containers: \(capabilities.capabilities.systemContainers)")
    lines.append("vm: \(capabilities.capabilities.vm)")
    lines.append("nested virtualization: \(capabilities.capabilities.nestedVirtualization)")
  }
  if let guidance = result.pathGuidance { lines.append(guidance) }
  lines.append("next: \(result.nextCommands.joined(separator: " && "))")
  return lines.joined(separator: "\n") + "\n"
}

func currentExecutablePath() -> String {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  var size = UInt32(buffer.count)
  guard _NSGetExecutablePath(&buffer, &size) == 0 else {
    return CommandLine.arguments.first ?? "macus"
  }
  let path = decodeCString(buffer)
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return decodeCString(resolved)
}

private func decodeCString(_ bytes: [CChar]) -> String {
  let end = bytes.firstIndex(of: 0) ?? bytes.count
  return String(decoding: bytes[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func decodeCString(_ pointer: UnsafePointer<CChar>) -> String {
  var length = 0
  while pointer[length] != 0 { length += 1 }
  let bytes = UnsafeBufferPointer(start: pointer, count: length).map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
}

func currentProcessHasVirtualizationEntitlement() -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
  process.arguments = ["-d", "--entitlements", ":-", currentExecutablePath()]
  let output = Pipe()
  let error = Pipe()
  process.standardOutput = output
  process.standardError = error
  guard (try? process.run()) != nil else { return false }
  process.waitUntilExit()
  let text =
    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    + String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  return text.contains("com.apple.security.virtualization")
}

private final class TerminalProgressSink: StartupProgressSink, @unchecked Sendable {
  private let lock = NSLock()
  private var renderer: ProgressRenderer
  private let write: @Sendable (String) -> Void
  init(rendering: ProgressRendering, write: @escaping @Sendable (String) -> Void) {
    renderer = ProgressRenderer(rendering: rendering)
    self.write = write
  }
  func emit(_ event: StartupProgressEvent) {
    lock.lock()
    let text = renderer.render(event, now: .now)
    lock.unlock()
    if let text { write(text) }
  }
  func cleanup() -> String {
    lock.lock()
    let text = renderer.cleanup()
    lock.unlock()
    return text
  }
}

private final class SignalCancellation: @unchecked Sendable {
  private var sources: [DispatchSourceSignal] = []
  init(task: Task<StartupResult, Error>) {
    for number in [SIGINT, SIGTERM] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { task.cancel() }
      source.resume()
      sources.append(source)
    }
  }
  func cancel() {
    for source in sources { source.cancel() }
    sources.removeAll()
    signal(SIGINT, SIG_DFL)
    signal(SIGTERM, SIG_DFL)
  }
}
