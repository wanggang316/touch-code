// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TouchCodeDependencies",
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
  ]
)
