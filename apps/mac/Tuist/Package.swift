// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TouchCodeDependencies",
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.23.1"),
  ]
)
