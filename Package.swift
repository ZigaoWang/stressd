// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "stressd",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "StressKit", targets: ["StressKit"]),
    .executable(name: "stressd", targets: ["stressd"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
  ],
  targets: [
    // All logic lives here. No CLI code, no printing: a SwiftUI menu bar app
    // links against this target too.
    .target(
      name: "StressKit",
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // Thin command line wrapper. The only target allowed to depend on
    // swift-argument-parser or to write to standard output.
    .executableTarget(
      name: "stressd",
      dependencies: [
        "StressKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "StressKitTests",
      dependencies: ["StressKit"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
  ]
)
