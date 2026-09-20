// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Winnie",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        // Pure logic: API client, SSE parsing, chat storage. No AppKit, testable.
        .target(name: "WinnieCore"),
        // Windows, views, system integration. A library so tools can drive the real UI.
        .target(
            name: "WinnieApp",
            dependencies: [
                "WinnieCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        .executableTarget(name: "Winnie", dependencies: ["WinnieApp"]),
        // Developer tool: renders the real chat panel to a PNG (swift run WinnieSnapshot out.png).
        .executableTarget(name: "WinnieSnapshot", dependencies: ["WinnieApp", "WinnieCore"]),
        .testTarget(name: "WinnieCoreTests", dependencies: ["WinnieCore"]),
    ]
)
