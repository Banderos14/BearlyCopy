// swift-tools-version:5.10
// BearlyCopy native macOS app (Phase 3A).
//
// PromptRelayKit holds everything reusable: JSON API v1 models, the Core CLI
// adapter, clipboard and store-watching services, the presentation model and
// the SwiftUI components. The future notch UI (Phase 3B) is a second surface
// over the same kit. PromptRelayApp is only the app lifecycle.
import PackageDescription

let package = Package(
    name: "PromptRelay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PromptRelayKit", targets: ["PromptRelayKit"]),
        .executable(name: "PromptRelayApp", targets: ["PromptRelayApp"]),
        // Phase 16: renders the app icon from Relay's drawing (scripts/make-app-icon.sh).
        .executable(name: "PromptRelayIcon", targets: ["PromptRelayIcon"]),
    ],
    targets: [
        .target(name: "PromptRelayKit", path: "Sources/PromptRelayKit"),
        .executableTarget(
            name: "PromptRelayApp",
            dependencies: ["PromptRelayKit"],
            path: "Sources/PromptRelayApp"
        ),
        .executableTarget(
            name: "PromptRelayIcon",
            dependencies: ["PromptRelayKit"],
            path: "Sources/PromptRelayIcon"
        ),
        .testTarget(
            name: "PromptRelayKitTests",
            dependencies: ["PromptRelayKit"],
            path: "Tests/PromptRelayKitTests"
        ),
    ]
)
