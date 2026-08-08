// swift-tools-version: 6.0
import PackageDescription

// HeftCore holds everything that is pure logic: markdown parsing, wikilink
// resolution, vault indexing, moment-style date tokens. It must never import
// AppKit or SwiftUI. That keeps it testable without a UI, and keeps a port
// (iOS, or Skip-transpiled Android) a question of writing a new shell only.
//
// Heft is the macOS shell: SwiftUI, NSTextView, FSEvents.
let package = Package(
    name: "Heft",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        // Pure-Swift LaTeX typesetting. Chosen over LaTeXSwiftUI/MathJaxSwift
        // because those run MathJax through JavaScriptCore, which would undo
        // the startup speed that is the whole point of a native app.
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
        // Kept only for its syntax-highlighting grammars, which back fenced
        // code blocks. Its own editor was evaluated and dropped: the wikilink
        // transform rewrites `[[a|b]]` suffixes, which breaks `![[img.png|500]]`.
        .package(url: "https://github.com/nodes-app/swift-markdown-engine.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "HeftCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            path: "Sources/HeftCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Heft",
            dependencies: [
                "HeftCore",
                "SwiftMath",
                .product(name: "MarkdownEngineCodeBlocks", package: "swift-markdown-engine"),
            ],
            path: "Sources/Heft",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HeftTests",
            dependencies: ["Heft", "HeftCore"],
            path: "Tests/HeftTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
