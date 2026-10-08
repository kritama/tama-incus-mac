// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "macus",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "Macus", targets: ["Macus"]),
    .executable(name: "macus", targets: ["MacusCommand"]),
  ],
  dependencies: [
    .package(url: "https://github.com/tuist/Noora.git", exact: "0.57.5")
  ],
  targets: [
    .target(name: "Macus", dependencies: [.product(name: "Noora", package: "Noora")]),
    .executableTarget(name: "MacusCommand", dependencies: ["Macus"]),
    .testTarget(name: "MacusTests", dependencies: ["Macus", "MacusCommand"]),
  ],
  swiftLanguageModes: [.v6]
)
