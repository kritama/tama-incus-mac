import Darwin
import Foundation
import os

@MainActor
public enum Daemon {
  public static func run(arguments: [String]) async throws {
    if arguments == ["capabilities"] {
      print(String(decoding: try JSON.encoder().encode(CapabilityDetector.detect()), as: UTF8.self))
      return
    }
    if arguments.isEmpty || arguments == ["--help"] {
      print(
        """
        tama-incus-mac — native macOS Incus host
        Usage: tama-incus-mac serve [--state-dir ABSOLUTE_PATH]
               tama-incus-mac capabilities
        Control: <state-dir>/runtime.sock; Incus: <state-dir>/incus.sock
        Default: ~/.tama/incus-mac. See docs/api.md for provisioning and lifecycle.
        """)
      return
    }
    guard arguments.first == "serve",
      arguments.count == 1
        || (arguments.count == 3 && arguments[1] == "--state-dir" && arguments[2].hasPrefix("/"))
    else {
      throw RuntimeError(.invalidRequest, "Use --help for supported arguments")
    }
    let directory =
      arguments.count == 3
      ? URL(fileURLWithPath: arguments[2])
      : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tama/incus-mac")
    let paths = RuntimePaths(directory: directory)
    let lock = try StateLock(paths: paths)
    let service = try RuntimeService(
      driver: VirtualMachineController(), store: StateStore(paths: paths))
    let server = try APIServer(service: service, paths: paths)
    let logger = Logger(subsystem: "com.kritama.tama-incus-mac", category: "daemon")
    logger.info("Control API: \(paths.controlSocket.path, privacy: .public)")
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let sources = [SIGTERM, SIGINT].map { number in
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { continuation.yield(()) }
      source.resume()
      return source
    }
    for await _ in stream {
      do { _ = try await service.stop() } catch {
        logger.error("Graceful termination failed: \(error.localizedDescription, privacy: .public)")
        // Keep serving if an operation is active, allowing a later shutdown signal.
        if (error as? RuntimeError)?.code == .conflict { continue }
        _ = try? await service.stop(force: true)
      }
      break
    }
    server.stop()
    continuation.finish()
    for source in sources { source.cancel() }
    withExtendedLifetime(lock) {}
  }
}
