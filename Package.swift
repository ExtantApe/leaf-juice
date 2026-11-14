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
        .executableTarget(name: "LeafJuice", dependencies: ["LeafJuiceCore", "LeafJuiceAdvisor"]),
        // Self-tests as a plain executable, so they run without Xcode (XCTest needs it).
        .executableTarget(name: "leafjuice-check", dependencies: ["LeafJuiceCore", "LeafJuiceAdvisor", "leafjuice-mcp"]),
        // Privacy layer for the optional advisor. It must never depend on LeafJuiceCore: see docs/ADVISOR-SECURITY.md.
        .target(name: "LeafJuiceAdvisor"),
        .executableTarget(name: "leafjuice-mcp", dependencies: ["LeafJuiceAdvisor"]),
        // How assistant sessions talk to a running LeafJuice: status, logs and the owner's list of commands.
        .executableTarget(name: "leafjuice-session"),
    ]
)
