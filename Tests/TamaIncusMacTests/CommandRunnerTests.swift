import Darwin
import Foundation
import Testing

@testable import TamaIncusMac

@Test func commandRunnerDrainsBothPipesAndRejectsOversizedOutput() async throws {
  let result = try await ProcessCommandRunner().run(
    executable: "/usr/bin/python3",
    arguments: [
      "-c",
      "import os, threading; t = threading.Thread(target=lambda: os.write(2, b'E' * 524288)); t.start(); os.write(1, b'O' * 524288); t.join()",
    ], environment: ProcessInfo.processInfo.environment, timeout: 5)
  #expect(result.status == 0)
  #expect(result.stdout == Data(repeating: 79, count: 524288))
  #expect(result.stderr == Data(repeating: 69, count: 524288))
  do {
    _ = try await ProcessCommandRunner().run(
      executable: "/usr/bin/python3",
      arguments: [
        "-c", "import os; os.write(1, b'X' * 2097152)",
      ], environment: ProcessInfo.processInfo.environment, timeout: 5)
    Issue.record("Oversized command output was accepted")
  } catch let error as RuntimeError {
    #expect(error.code == .io)
    #expect(error.message.contains("1 MiB"))
  }
}

@Test func commandRunnerCancellationReapsTheChild() async throws {
  let root = try commandTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let pidFile = root.appendingPathComponent("pid")
  let task = Task {
    try await ProcessCommandRunner().run(
      executable: "/usr/bin/python3",
      arguments: [
        "-c",
        "import os, sys, time; open(sys.argv[1], 'w').write(str(os.getpid())); time.sleep(30)",
        pidFile.path,
      ], environment: ProcessInfo.processInfo.environment, timeout: 10)
  }
  let pid = try await commandTestPID(pidFile)
  defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
  let started = ContinuousClock.now
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(started.duration(to: .now) < .seconds(2))
  #expect(kill(pid, 0) == -1)
  #expect(errno == ESRCH)
}

@Test func commandRunnerDoesNotWaitForDescendantPipeEOF() async throws {
  let root = try commandTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let pidFile = root.appendingPathComponent("descendant")
  let started = ContinuousClock.now
  let result = try await ProcessCommandRunner().run(
    executable: "/usr/bin/python3",
    arguments: [
      "-c",
      "import subprocess, sys; p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); open(sys.argv[1], 'w').write(str(p.pid)); print('done', flush=True)",
      pidFile.path,
    ], environment: ProcessInfo.processInfo.environment, timeout: 10)
  let pid = try await commandTestPID(pidFile)
  defer { kill(pid, SIGKILL) }
  #expect(result.status == 0)
  #expect(result.stdout == Data("done\n".utf8))
  #expect(started.duration(to: .now) < .seconds(10))
}

private func commandTestDirectory() throws -> URL {
  let root = URL(fileURLWithPath: "/tmp/timcmd\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return root
}

private func commandTestPID(_ path: URL) async throws -> pid_t {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while ContinuousClock.now < deadline {
    if let contents = try? String(contentsOf: path, encoding: .utf8), let pid = pid_t(contents) {
      return pid
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw RuntimeError(.timeout, "Fixture did not publish its PID")
}
