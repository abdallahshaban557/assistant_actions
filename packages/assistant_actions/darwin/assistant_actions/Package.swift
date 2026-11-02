// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "assistant_actions",
  platforms: [.iOS("17.0"), .macOS("14.0")],
  products: [.library(name: "assistant-actions", targets: ["assistant_actions"])],
  dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
  targets: [
    // Pigeon's FFI bridge (FFIgen trampolines). SwiftPM can't mix Objective-C
    // and Swift in one target, so it gets its own.
    .target(
      name: "assistant_actions_objc_gen",
      dependencies: [],
      publicHeadersPath: "."),
    .target(
      name: "assistant_actions",
      dependencies: [
        "assistant_actions_objc_gen",
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ]),
  ]
)
