#!/usr/bin/env swift
// Draws Heft's app icon and assembles Resources/Heft.icns.
//
//   swift Scripts/make-icon.swift
//
// The icon is generated rather than checked in as a binary because this
// project has no Xcode and therefore no asset catalogue: there is nowhere for
// a designed .icns to live and be edited. Drawing it in code keeps it in
// version control as something diffable, and every size is rendered at its
// native resolution rather than downsampled from one master, which is what
// keeps the 16pt version from turning to mush.
//
// "Heft" is the German word for a notebook, so that is what it shows.

import AppKit

// MARK: - Palette

/// Deep indigo through violet. Fixed sRGB values, not system colours: an icon
/// is a fixed asset and must not change with the user's appearance or accent.
let topColor = NSColor(srgbRed: 0.353, green: 0.325, blue: 0.855, alpha: 1)
let bottomColor = NSColor(srgbRed: 0.451, green: 0.239, blue: 0.702, alpha: 1)
let pageColor = NSColor(srgbRed: 0.988, green: 0.988, blue: 1.0, alpha: 1)
let spineColor = NSColor(srgbRed: 0.996, green: 0.702, blue: 0.290, alpha: 1)
let ruleColor = NSColor(srgbRed: 0.353, green: 0.325, blue: 0.855, alpha: 0.30)

/// Draws the icon into `context` on a `side`×`side` canvas.
///
/// Everything is expressed as a fraction of `side`, so the same code renders
/// every size. macOS reserves a margin around the rounded body for the shadow;
/// the ratios below are Apple's published icon grid.
func drawIcon(side: CGFloat, into context: CGContext) {
    let inset = side * 0.0977
    let body = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = body.width * 0.2246
    let outline = CGPath(
        roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    context.saveGState()
    context.addPath(outline)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.minX, y: body.maxY),
            end: CGPoint(x: body.maxX, y: body.minY),
            options: []
        )
    }
    context.restoreGState()

    // The page, inset within the body and shifted right to leave room for the
    // spine. Rounded on the right only would be truer to a real notebook, but
    // it reads as a rendering glitch at 16pt, so all four corners are rounded.
    let page = CGRect(
        x: body.minX + body.width * 0.255,
        y: body.minY + body.height * 0.175,
        width: body.width * 0.50,
        height: body.height * 0.65
    )
    let pageRadius = page.width * 0.075

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -body.height * 0.012),
        blur: body.height * 0.045,
        color: NSColor(srgbRed: 0.10, green: 0.05, blue: 0.25, alpha: 0.35).cgColor
    )
    context.setFillColor(pageColor.cgColor)
    context.addPath(CGPath(
        roundedRect: page, cornerWidth: pageRadius, cornerHeight: pageRadius, transform: nil
    ))
    context.fillPath()
    context.restoreGState()

    // The spine: a bound edge down the left of the page.
    let spine = CGRect(
        x: page.minX - body.width * 0.075,
        y: page.minY,
        width: body.width * 0.105,
        height: page.height
    )
    context.setFillColor(spineColor.cgColor)
    context.addPath(CGPath(
        roundedRect: spine, cornerWidth: pageRadius, cornerHeight: pageRadius, transform: nil
    ))
    context.fillPath()
    // Square off the spine's right edge so it meets the page cleanly.
    context.fill(CGRect(
        x: spine.maxX - pageRadius, y: spine.minY, width: pageRadius * 2, height: spine.height
    ))

    // Ruled lines. Dropped below 64pt, where they collapse into a grey smear
    // and cost more legibility than they add.
    guard side >= 64 else { return }
    let ruleHeight = page.height * 0.050
    let ruleInset = page.width * 0.14
    context.setFillColor(ruleColor.cgColor)
    // The last line is short, the way a paragraph ends. Four of them fill the
    // page evenly; three left the bottom third looking empty.
    for (index, widthFraction) in [0.78, 0.78, 0.78, 0.44].enumerated() {
        let y = page.maxY - page.height * (0.21 + Double(index) * 0.175)
        let rule = CGRect(
            x: page.minX + ruleInset,
            y: y,
            width: (page.width - ruleInset * 2) * widthFraction,
            height: ruleHeight
        )
        context.addPath(CGPath(
            roundedRect: rule,
            cornerWidth: ruleHeight / 2, cornerHeight: ruleHeight / 2, transform: nil
        ))
        context.fillPath()
    }
}

// MARK: - Rendering

func renderPNG(side: Int) -> Data {
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a \(side)pt bitmap context") }

    drawIcon(side: CGFloat(side), into: context)

    guard let image = context.makeImage() else { fatalError("could not render \(side)pt") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(side)pt as PNG")
    }
    return data
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("Heft.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Every entry `iconutil` expects. Each is rendered at its true pixel size, so
// the small ones are drawn for their size rather than shrunk from 1024.
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for entry in entries {
    try renderPNG(side: entry.pixels).write(to: iconset.appendingPathComponent(entry.name))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = [
    "-c", "icns", iconset.path,
    "-o", resources.appendingPathComponent("Heft.icns").path,
]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

// The .iconset is a build artefact; the .icns is what ships.
try FileManager.default.removeItem(at: iconset)
print("Wrote \(resources.appendingPathComponent("Heft.icns").path)")
