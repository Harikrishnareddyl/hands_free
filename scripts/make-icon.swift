#!/usr/bin/env swift
//
// Generates a 1024×1024 PNG app icon.
// Design: violet-to-blue diagonal gradient in a rounded square, with the
// SF Symbols "mic.fill" glyph rendered in white at the center.
//
// Usage:  swift scripts/make-icon.swift <output.png>
//

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png"

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Rounded-square gradient background (Big Sur-style corner radius ≈ 180px on 1024).
let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 180, yRadius: 180)

let gradient = NSGradient(colors: [
    NSColor(red: 0.42, green: 0.20, blue: 0.95, alpha: 1.0),  // deep violet (top-left)
    NSColor(red: 0.18, green: 0.50, blue: 0.95, alpha: 1.0),  // bright blue (bottom-right)
])!
bgPath.addClip()
gradient.draw(in: bgPath.bounds, angle: -45)

// Soft top highlight — elliptical glow clipped by the rounded square — adds depth.
NSColor.white.withAlphaComponent(0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: -200, y: 520, width: 1424, height: 700)).fill()

// Microphone glyph: SF Symbols "mic.fill" in white, scaled big.
var config = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium)
config = config.applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

if let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let ss = symbol.size
    let rect = NSRect(
        x: (size - ss.width) / 2,
        y: (size - ss.height) / 2 - 20,   // shift up slightly for visual balance
        width: ss.width,
        height: ss.height
    )
    symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
}

image.unlockFocus()

// Write PNG.
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render PNG\n".utf8))
    exit(1)
}

try data.write(to: URL(fileURLWithPath: outputPath))
print("✓ \(outputPath) (\(data.count / 1024) KB)")
