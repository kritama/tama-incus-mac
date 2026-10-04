import Foundation
import TamaIncusMac

@main
struct TimMain {
  static func main() async {
    let code = await TimCLI.run(
      arguments: Array(CommandLine.arguments.dropFirst()),
      environment: ProcessInfo.processInfo.environment)
    if code != 0 { exit(code) }
  }
}
