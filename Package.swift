// swift-tools-version: 5.9
import PackageDescription

// Xcode builds the app. This package tests its core without Accessibility access
// or quitting any real applications.
let package = Package(
    name: "SlowQuitCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SlowQuitCore", targets: ["SlowQuitCore"])],
    targets: [
        .target(name: "SlowQuitCore", path: "SlowQuit/Core"),
        .testTarget(name: "SlowQuitCoreTests", dependencies: ["SlowQuitCore"], path: "Tests")
    ]
)
