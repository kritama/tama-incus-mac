// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "tama-incus-mac",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "TamaIncusMac", targets: ["TamaIncusMac"]),
    .executable(name: "tama-incus-mac", targets: ["tama-incus-mac"]),
    .executable(name: "tim", targets: ["tim"]),
  ],
  targets: [
    .target(name: "TamaIncusMac"),
    .executableTarget(name: "tama-incus-mac", dependencies: ["TamaIncusMac"]),
    .executableTarget(name: "tim", dependencies: ["TamaIncusMac"]),
    .testTarget(name: "TamaIncusMacTests", dependencies: ["TamaIncusMac", "tim"]),
  ],
  swiftLanguageModes: [.v6]
)
