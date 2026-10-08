import Foundation

struct StartupDependencies: Sendable {
  var transport: any LocalHTTPTransport
  var runner: any LocalCommandRunner
  var downloader: any ApplianceDownloader
  var launchControl: any LaunchControl
  var capabilities: @Sendable () async -> HostCapabilities
  var hasEntitlement: @Sendable () -> Bool
  var executablePath: @Sendable () -> String
  var now: @Sendable () -> ContinuousClock.Instant
  var homeDirectory: URL
  var launchAgentsDirectory: URL
  var uid: uid_t
  var catalog: ApplianceCatalogEntry
  var sink: any StartupProgressSink
}

struct StartupCoordinator {
  var dependencies: StartupDependencies

  func run(_ request: StartupRequest) async throws -> StartupResult {
    let budget = StartupBudget(seconds: request.timeout, now: dependencies.now())
    let context = StartContext(
      request: request, budget: budget, dependencies: dependencies, operationID: request.operationID
    )
    return try await context.run()
  }
}

private final class StartContext: @unchecked Sendable {
  var request: StartupRequest
  var budget: StartupBudget
  var dependencies: StartupDependencies
  var operationID: String
  var serviceOwnership = "launchd"
  var serviceLabel: String?
  var startDispatched = false
  var currentStage: StartupStage = .preflight

  init(
    request: StartupRequest, budget: StartupBudget, dependencies: StartupDependencies,
    operationID: String
  ) {
    self.request = request
    self.budget = budget
    self.dependencies = dependencies
    self.operationID = operationID
  }

  func run() async throws -> StartupResult {
    do {
      try await preflight()
      let paths = RuntimePaths(directory: request.stateDirectory)
      try paths.prepare()
      let lock = try BootstrapLock(directory: paths.directory)
      defer { lock.release() }
      serviceLabel = LaunchAgentPlan.label(
        stateDirectory: paths.directory, home: dependencies.homeDirectory)
      try await rejectLegacy(paths)
      let kind = try BootstrapStore.existingRuntime(paths.directory)
      let manifest: URL
      if kind == .absent {
        manifest = try await prepareAbsent(paths)
      } else {
        emit(.acquisition, .skipped, detail: "existing runtime")
        emit(.verification, .skipped)
        emit(.preparation, .skipped)
        emit(.runtimeCreation, .skipped)
        guard let loaded = try loadManifest(paths) else {
          throw RuntimeError(.io, "Existing runtime is missing its appliance manifest path")
        }
        manifest = loaded
        _ = manifest
      }
      let ownership = try await ensureService(paths)
      if kind == .absent { try await createRuntime(paths, manifest: try publishedManifest(paths)) }
      let capabilities = try await bootAndWait(paths)
      let client = try await configureClient(paths)
      emit(.clientSetup, .complete)
      return StartupResult(
        ready: true, connected: true, stateDirectory: paths.directory.path, remote: request.remote,
        incus: client.executable, installed: client.installed,
        serviceOwnership: ownership.ownership, serviceLabel: ownership.label,
        capabilities: capabilities, nextCommands: client.commands, pathGuidance: client.guidance,
        observedState: "ready")
    } catch is CancellationError {
      throw StartupInterrupted(message: await interruptedMessage())
    } catch let error as StartupInterrupted {
      throw error
    } catch {
      let failed = error as? RuntimeError ?? RuntimeError(.io, error.localizedDescription)
      emit(currentStage, .failed, detail: failed.message, code: failed.code.rawValue)
      throw failed
    }
  }

  private func preflight() async throws {
    emit(.preflight, .active)
    try BootstrapStore.validateState(request.stateDirectory)
    let host = await dependencies.capabilities()
    guard host.supported else {
      throw RuntimeError(
        .unavailable,
        "Apple virtualization is unavailable on this host. macus start will not download or create a runtime."
      )
    }
    guard dependencies.hasEntitlement() else {
      throw RuntimeError(
        .unavailable,
        "The macus executable is missing the virtualization entitlement. Install the entitled binary before macus start."
      )
    }
    let client = IncusClientService(
      runner: dependencies.runner,
      streams: MacusStreams(writeOutput: { _ in }, writeError: { _ in }),
      environment: request.environment)
    switch try client.availability(override: request.incusOverride) {
    case .missing:
      throw RuntimeError(
        .unavailable,
        "Incus CLI was not found on PATH and Homebrew is not installed. Install Homebrew from https://brew.sh, then rerun macus start. macus does not install Homebrew or use sudo."
      )
    case .executable(let path):
      let socket = request.stateDirectory.appendingPathComponent("incus.sock").path
      if try await client.conflictingRemote(
        executable: path, remote: request.remote, socketPath: socket, timeout: request.timeout,
        deadline: budget.deadline)
      {
        throw RuntimeError(
          .conflict,
          "Remote \(request.remote) already points at a different address. Choose another --remote. Existing remotes and runtime data were preserved."
        )
      }
    case .homebrew:
      break
    }
    emit(.preflight, .complete)
  }

  private func prepareAbsent(_ paths: RuntimePaths) async throws -> URL {
    emit(.acquisition, .active)
    let acquisition = ApplianceAcquisition(downloader: dependencies.downloader)
    let cache = try await acquisition.materialize(
      entry: dependencies.catalog, directory: paths.directory, budget: budget, now: dependencies.now
    ) { completed, total in
      self.emit(.acquisition, .active, completed: completed, total: total)
    }
    emit(.acquisition, .complete, detail: "verified")
    emit(.verification, .complete)
    emit(.preparation, .active)
    let timeout = try budget.remainingSeconds(at: dependencies.now())
    let manifest = try await SeedPreparation.prepare(
      entry: dependencies.catalog, cache: cache, runner: dependencies.runner, timeout: timeout,
      environment: request.environment)
    let journal = BootstrapJournal(
      catalogID: dependencies.catalog.id, payloadRevision: EmbeddedGuestPayload.revision,
      archiveSHA512: dependencies.catalog.archiveSHA512, rawSHA256: dependencies.catalog.rawSHA256,
      acquired: true, prepared: true)
    try BootstrapStore.saveJournal(journal, directory: paths.directory)
    _ = journal
    emit(.preparation, .complete)
    return manifest
  }

  private func ensureService(_ paths: RuntimePaths) async throws -> (
    ownership: String, label: String?
  ) {
    emit(.serviceActivation, .active)
    let label = LaunchAgentPlan.label(
      stateDirectory: paths.directory, home: dependencies.homeDirectory)
    serviceLabel = label
    try await rejectLegacy(paths)
    let executable = dependencies.executablePath()
    guard isAbsoluteExecutablePath(executable) else {
      throw RuntimeError(.invalidConfiguration, "Service executable path must be absolute")
    }
    let expected = LaunchAgentPlan.arguments(
      executable: executable, stateDirectory: paths.directory)
    // A registered job is identified from launchctl before any start or bootstrap.
    if let loaded = try await dependencies.launchControl.printJob(
      label: label, timeout: try budget.remainingSeconds(at: dependencies.now()))
    {
      // Identity comes from launchctl, not the mutable on-disk plist.
      try validateLoadedJob(loaded, label: label, arguments: expected)
      if !loaded.loaded {
        try Task.checkCancellation()
        try await dependencies.launchControl.kickstart(
          label: label, timeout: try budget.remainingSeconds(at: dependencies.now()))
      }
      try await waitForEndpoint(paths)
      try Task.checkCancellation()
      guard dependencies.now() < budget.deadline else {
        throw RuntimeError(.timeout, "Startup deadline exceeded")
      }
      serviceOwnership = "launchd"
      emit(.serviceActivation, .complete, detail: loaded.loaded ? "reused" : "kickstarted")
      return ("launchd", label)
    }
    if try await compatibleDaemon(paths) {
      serviceOwnership = "foreground"
      emit(.serviceActivation, .complete, detail: "foreground")
      return ("foreground", nil)
    }
    let plist = try LaunchAgentPlan.write(
      stateDirectory: paths.directory, home: dependencies.homeDirectory,
      launchAgents: dependencies.launchAgentsDirectory, executable: executable)
    if !LaunchAgentPlan.isDefault(paths.directory, home: dependencies.homeDirectory) {
      let def = dependencies.launchAgentsDirectory.appendingPathComponent("com.upmaru.macus.plist")
      if FileManager.default.fileExists(atPath: def.path),
        try plistArguments(def)?.contains(paths.directory.path) != true
      {
        // Isolated registration must not replace the default agent. Leaving it untouched is required.
      }
    }
    try await dependencies.launchControl.bootstrap(
      plist: plist, timeout: try budget.remainingSeconds(at: dependencies.now()))
    try await waitForEndpoint(paths)
    serviceOwnership = "launchd"
    emit(.serviceActivation, .complete)
    return ("launchd", label)
  }

  private func createRuntime(_ paths: RuntimePaths, manifest: URL) async throws {
    emit(.runtimeCreation, .active)
    let host = await dependencies.capabilities()
    var configuration = RuntimeConfiguration(
      applianceManifestPath: manifest.path,
      seedPath: manifest.deletingLastPathComponent().appendingPathComponent("seed.iso").path)
    configuration.nestedVirtualization = host.nestedVirtualization
    configuration.readinessTimeoutSeconds = 1_800
    configuration.shares = []
    let body = try JSON.encoder().encode(configuration)
    let response = try await control("POST", "/v1/runtime/create", body, paths: paths)
    guard (200...299).contains(response.status) else {
      throw responseFailure(status: response.status, body: response.body)
    }
    emit(.runtimeCreation, .complete)
  }

  private func bootAndWait(_ paths: RuntimePaths) async throws -> RuntimeCapabilities {
    emit(.provisioning, .active)
    let status = try await statusObject(paths)
    if jsonString(status["state"]) == "ready" {
      let capabilities = try await liveCapabilities(paths)
      emit(.provisioning, .skipped, detail: "already ready")
      emit(.readiness, .complete)
      return capabilities
    }
    if jsonString(status["state"]) == "starting" {
      throw RuntimeError(
        .conflict,
        "A runtime mutation is already in progress. Retry after it finishes; disks were preserved."
      )
    }
    emit(.readiness, .active)
    startDispatched = true
    let remaining = try budget.remainingSeconds(at: dependencies.now())
    let body = try JSONSerialization.data(withJSONObject: ["remaining_seconds": remaining])
    let poll = Task { await pollProgress(paths) }
    defer { poll.cancel() }
    let response = try await control("POST", "/v1/runtime/start", body, paths: paths)
    guard (200...299).contains(response.status) else {
      throw responseFailure(status: response.status, body: response.body)
    }
    let capabilities = try await liveCapabilities(paths)
    emit(.provisioning, .complete)
    emit(.readiness, .complete)
    return capabilities
  }

  private func configureClient(_ paths: RuntimePaths) async throws -> (
    executable: String, installed: Bool, commands: [String], guidance: String?
  ) {
    emit(.clientSetup, .active)
    let status = try await statusObject(paths)
    guard jsonString(status["state"]) == "ready", let socket = jsonString(status["incus_socket"])
    else {
      throw RuntimeError(
        .unavailable,
        "Runtime is not ready. Client setup was not started and runtime data was preserved."
      )
    }
    let service = IncusClientService(
      runner: dependencies.runner,
      streams: MacusStreams(
        writeOutput: { _ in },
        writeError: { text in
          self.dependencies.sink.emit(
            self.event(.clientSetup, .active, detail: String(text.prefix(160))))
        }),
      environment: request.environment)
    do {
      let result = try await service.register(
        remote: request.remote, setDefault: request.setDefault,
        incusOverride: request.incusOverride,
        socketPath: socket, timeout: request.timeout, deadline: budget.deadline)
      let directory = URL(fileURLWithPath: result.executable).deletingLastPathComponent().path
      let guidance =
        result.onPath
        ? nil
        : "incus is not on PATH. Use \(result.executable) or add \(directory) to PATH. macus does not edit shell profiles."
      let command =
        result.onPath
        ? "incus list \(request.remote):" : "\(result.executable) list \(request.remote):"
      return (result.executable, result.installed, [command], guidance)
    } catch {
      let runtime = error as? RuntimeError ?? RuntimeError(.io, error.localizedDescription)
      throw RuntimeError(
        runtime.code,
        "\(runtime.message) Client setup failed after the runtime became ready; retry macus start without recreating disks."
      )
    }
  }

  private func compatibleDaemon(_ paths: RuntimePaths) async throws -> Bool {
    guard FileManager.default.fileExists(atPath: paths.controlSocket.path) else { return false }
    let status: LocalHTTPResponse
    do {
      status = try await control("GET", "/v1/runtime/status", Data(), paths: paths)
    } catch let error as RuntimeError where error.code == .invalidConfiguration {
      throw RuntimeError(
        .invalidConfiguration,
        "The control endpoint is unsafe or owned by another user. macus start will not replace it."
      )
    } catch {
      return false
    }
    guard (200...299).contains(status.status) else { return false }
    let progress = try await control("GET", "/v1/runtime/progress", Data(), paths: paths)
    if progress.status == 404 {
      throw RuntimeError(
        .invalidConfiguration,
        "An incompatible daemon is serving this state. Stop that daemon and rerun macus start with the current executable. macus will not replace it."
      )
    }
    guard (200...299).contains(progress.status) else {
      throw responseFailure(status: progress.status, body: progress.body)
    }
    return true
  }

  private func validateLoadedJob(
    _ job: LaunchJob, label: String, arguments expected: [String]
  ) throws {
    guard !job.programArguments.isEmpty else {
      throw RuntimeError(
        .invalidConfiguration,
        "launchctl did not report an unambiguous executable and state for \(label). macus start will not start or replace that service."
      )
    }
    guard job.executable == expected.first, job.programArguments == expected else {
      throw RuntimeError(
        .conflict,
        "Service \(label) already points at a different executable or state. macus start will not replace that plist."
      )
    }
  }

  private func rejectLegacy(_ paths: RuntimePaths) async throws {
    let executable = dependencies.executablePath()
    let label = LaunchAgentPlan.label(
      stateDirectory: paths.directory, home: dependencies.homeDirectory)
    let chosen = LaunchAgentPlan.plistURL(
      stateDirectory: paths.directory, home: dependencies.homeDirectory,
      launchAgents: dependencies.launchAgentsDirectory)
    try LaunchAgentPlan.refuseConflictingDestination(
      chosen, label: label,
      arguments: LaunchAgentPlan.arguments(executable: executable, stateDirectory: paths.directory))
    let directories = [
      dependencies.launchAgentsDirectory,
      paths.directory.appendingPathComponent("launchd", isDirectory: true),
    ]
    for directory in directories {
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
        continue
      }
      for name in names where name.hasSuffix(".plist") {
        let url = directory.appendingPathComponent(name)
        guard let arguments = try plistArguments(url) else { continue }
        let label = (name as NSString).deletingPathExtension
        let legacy = LegacyService.labels.contains(label) || label.hasPrefix("com.kritama.")
        let ours = label == serviceLabel
        if LaunchAgentPlan.targets(arguments, stateDirectory: paths.directory) {
          if legacy {
            throw RuntimeError(
              .conflict,
              "Legacy service \(label) targets this state. Unload it explicitly and remove its plist before macus start. Data was preserved and no second daemon was created."
            )
          }
          if !ours && label != "com.upmaru.macus" && !label.hasPrefix("com.upmaru.macus.") {
            throw RuntimeError(
              .conflict,
              "Service \(label) already targets this state. macus start will not replace it or start a second daemon."
            )
          }
          let expected = LaunchAgentPlan.arguments(
            executable: dependencies.executablePath(), stateDirectory: paths.directory)
          if arguments != expected && ours {
            throw RuntimeError(
              .conflict,
              "Service \(label) points at a different executable or state. macus start will not replace that plist."
            )
          }
        }
      }
    }
  }

  private func waitForEndpoint(_ paths: RuntimePaths) async throws {
    let deadline = budget.deadline
    while dependencies.now() < deadline {
      try Task.checkCancellation()
      if FileManager.default.fileExists(atPath: paths.controlSocket.path),
        (try? await compatibleDaemon(paths)) == true
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RuntimeError(
      .timeout, "The background service did not open its control endpoint before the deadline")
  }

  private func pollProgress(_ paths: RuntimePaths) async {
    while !Task.isCancelled {
      if let response = try? await control("GET", "/v1/runtime/progress", Data(), paths: paths),
        (200...299).contains(response.status),
        let object = try? jsonObject(response.body)
      {
        let phase = jsonString(object["phase"])
        let reboot = jsonBool(object["expected_reboot"]) == true
        emit(.provisioning, .active, detail: phase, reboot: reboot)
        if jsonBool(object["ready"]) == true {
          break
        }
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private func liveCapabilities(_ paths: RuntimePaths) async throws -> RuntimeCapabilities {
    let health = try await control("GET", "/v1/runtime/health", Data(), paths: paths)
    guard (200...299).contains(health.status) else {
      throw responseFailure(status: health.status, body: health.body)
    }
    let decoded = try JSON.decoder().decode(GuestHealth.self, from: health.body)
    guard decoded.protocolVersion == 1 else {
      throw RuntimeError(
        .unavailable, "Guest health protocol is not live. Progress markers are not readiness.")
    }
    let capabilities = try await control("GET", "/v1/runtime/capabilities", Data(), paths: paths)
    guard (200...299).contains(capabilities.status) else {
      throw responseFailure(status: capabilities.status, body: capabilities.body)
    }
    return try JSON.decoder().decode(RuntimeCapabilities.self, from: capabilities.body)
  }

  private func statusObject(_ paths: RuntimePaths) async throws -> [String: Any] {
    let response = try await control("GET", "/v1/runtime/status", Data(), paths: paths)
    guard (200...299).contains(response.status) else {
      throw responseFailure(status: response.status, body: response.body)
    }
    return try jsonObject(response.body)
  }

  private func control(_ method: String, _ path: String, _ body: Data, paths: RuntimePaths)
    async throws
    -> LocalHTTPResponse
  {
    let timeout = try budget.remainingSeconds(at: dependencies.now())
    return try await dependencies.transport.request(
      socket: paths.controlSocket, method: method, path: path, body: body, timeout: timeout)
  }

  private func publishedManifest(_ paths: RuntimePaths) throws -> URL {
    paths.directory.appendingPathComponent("appliance-cache", isDirectory: true)
      .appendingPathComponent(dependencies.catalog.id, isDirectory: true)
      .appendingPathComponent("manifest.json")
  }

  private func loadManifest(_ paths: RuntimePaths) throws -> URL? {
    guard FileManager.default.fileExists(atPath: paths.config.path) else { return nil }
    let object =
      try JSONSerialization.jsonObject(with: Data(contentsOf: paths.config)) as? [String: Any]
    guard let path = object?["appliance_manifest_path"] as? String else { return nil }
    return URL(fileURLWithPath: path)
  }

  private func plistArguments(_ url: URL) throws -> [String]? {
    guard let object = try dependencies.launchControl.plist(at: url) else { return nil }
    return object["ProgramArguments"] as? [String]
  }

  private func interruptedMessage() async -> String {
    let paths = RuntimePaths(directory: request.stateDirectory)
    var observed: String?
    if FileManager.default.fileExists(atPath: paths.controlSocket.path),
      let response = try? await dependencies.transport.request(
        socket: paths.controlSocket, method: "GET", path: "/v1/runtime/status", body: Data(),
        timeout: 2),
      (200...299).contains(response.status),
      let object = try? jsonObject(response.body)
    {
      observed = jsonString(object["state"])
    }
    if startDispatched {
      let state = observed ?? "unknown"
      return
        "Start interrupted. Observed runtime state is \(state). The guest was not force-stopped; run macus runtime stop if you need to stop it. Disks and logs were preserved."
    }
    return
      "Start interrupted before a daemon-owned boot was dispatched. No guest was force-stopped. Disks and logs were preserved."
  }

  private func emit(
    _ stage: StartupStage, _ state: StartupStageState, completed: Int64? = nil, total: Int64? = nil,
    detail: String? = nil, reboot: Bool = false, code: String? = nil
  ) {
    dependencies.sink.emit(
      event(
        stage, state, completed: completed, total: total, detail: detail, reboot: reboot, code: code
      )
    )
  }

  private func event(
    _ stage: StartupStage, _ state: StartupStageState, completed: Int64? = nil, total: Int64? = nil,
    detail: String? = nil, reboot: Bool = false, code: String? = nil
  ) -> StartupProgressEvent {
    currentStage = stage
    let elapsed = max(0, Int(budget.started.duration(to: dependencies.now()).components.seconds))
    return StartupProgressEvent(
      operationID: operationID, stage: stage, state: state, elapsedSeconds: elapsed,
      completedBytes: completed, totalBytes: total, detail: detail, errorCode: code,
      expectedReboot: reboot)
  }
}
