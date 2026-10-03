import Darwin
import Foundation
import TamaIncusMac

@main
struct TamaIncusMacMain {
  static func main() async {
    do { try await Daemon.run(arguments: Array(CommandLine.arguments.dropFirst())) } catch {
      let message = "tama-incus-mac: \(error.localizedDescription)\n"
      try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
      exit(1)
    }
  }
}
