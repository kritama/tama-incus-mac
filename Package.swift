// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "tama-incus-mac",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "TamaIncusMac", targets: ["TamaIncusMac"]),
    .executable(name: "tama-incus-mac", targets: ["tama-incus-mac"]),
  ],
  targets: [
    .target(name: "TamaIncusMac"),
    .executableTarget(name: "tama-incus-mac", dependencies: ["TamaIncusMac"]),
    .testTarget(name: "TamaIncusMacTests", dependencies: ["TamaIncusMac"]),
  ],
  swiftLanguageModes: [.v6]
)
