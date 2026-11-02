// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "assistant_actions",
  platforms: [.iOS("17.0"), .macOS("14.0")],
  products: [.library(name: "assistant-actions", targets: ["assistant_actions"])],
  dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
  targets: [
    .target(
      name: "assistant_actions",
      dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")])
  ]
)
