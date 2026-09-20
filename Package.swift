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
        .executableTarget(
            name: "Winnie",
            dependencies: [
                "WinnieCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        .testTarget(name: "WinnieCoreTests", dependencies: ["WinnieCore"]),
    ]
)
