// swift-tools-version: 6.1

import PackageDescription

// Authored ASS/SSA styling, re-exported for both apps. AetherEngine hands hosts the raw ASS
// event lines, the script header and the container's fonts (LoadOptions.preserveASSMarkup);
// the actual paint is libass's job. swift-ass-renderer wraps libass and the font stack in
// iOS/tvOS binaries, and is pinned here so neither app depends on its transitive package graph.
let package = Package(
    name: "AssRenderingFeatures",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
    ],
    products: [
        .library(name: "AssRenderingFeatures", targets: ["AssRenderingFeatures"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/mihai8804858/swift-ass-renderer",
            exact: "1.3.1"
        ),
    ],
    targets: [
        .target(
            name: "AssRenderingFeatures",
            dependencies: [.product(name: "SwiftAssRenderer", package: "swift-ass-renderer")]
        ),
    ]
)
