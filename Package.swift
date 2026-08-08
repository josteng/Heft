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
        // TextKit 2 live-styling editor. Evaluated unmodified first; its
        // wikilink transform rewrites `[[a|b]]` suffixes, which matters for
        // `![[img.png|500]]` widths. See README for the standing caveat.
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
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineCodeBlocks", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineLatex", package: "swift-markdown-engine"),
            ],
            path: "Sources/Heft",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // No test target: XCTest and swift-testing both ship with Xcode, not
        // with the Command Line Tools this project builds against, so `swift
        // test` cannot run here. The equivalent assertions live in
        // HeftCore/SelfCheck.swift and run via `swift run Heft selftest`.
    ]
)
