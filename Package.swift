// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "macus",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "Macus", targets: ["Macus"]),
    .executable(name: "macus", targets: ["MacusCommand"]),
  ],
  targets: [
    .target(name: "Macus"),
    .executableTarget(name: "MacusCommand", dependencies: ["Macus"]),
    .testTarget(name: "MacusTests", dependencies: ["Macus", "MacusCommand"]),
  ],
  swiftLanguageModes: [.v6]
)
