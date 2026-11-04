// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LeafJuice",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LeafJuice", targets: ["LeafJuice"])],
    targets: [
        // Everything testable: no SwiftUI, no AppKit.
        .target(name: "LeafJuiceCore"),
        // The Mac app.
        .executableTarget(name: "LeafJuice", dependencies: ["LeafJuiceCore"]),
        // Self-tests as a plain executable, so they run without Xcode (XCTest needs it).
        .executableTarget(name: "leafjuice-check", dependencies: ["LeafJuiceCore"]),
    ]
)
