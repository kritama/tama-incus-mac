import Foundation
import Macus

@main
struct MacusMain {
  static func main() async {
    let code = await MacusCLI.run(
      arguments: Array(CommandLine.arguments.dropFirst()),
      environment: ProcessInfo.processInfo.environment)
    if code != 0 { exit(code) }
  }
}
