#!/usr/bin/env swift
// Draws the Committo app icon (gradient squircle + commit graph glyph) and writes AppIcon.icns.
// Usage: swift Scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); squircle.fill()
    ctx.restoreGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(red: 0.42, green: 0.36, blue: 1, alpha: 1), NSColor(red: 0.0, green: 0.78, blue: 0.85, alpha: 1)])!.draw(in: rect, angle: -50)
    // glossy highlight
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), .clear])!.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    // commit graph glyph: main line with a branch that merges back
    let white = NSColor.white
    white.setStroke(); white.setFill()
    let lw = s * 0.045
    let top = CGPoint(x: s * 0.36, y: s * 0.78), mid = CGPoint(x: s * 0.36, y: s * 0.5), bot = CGPoint(x: s * 0.36, y: s * 0.22)
    let br = CGPoint(x: s * 0.66, y: s * 0.5)
    let line = NSBezierPath(); line.lineWidth = lw; line.lineCapStyle = .round
    line.move(to: top); line.line(to: bot); line.stroke()
    let curve = NSBezierPath(); curve.lineWidth = lw; curve.lineCapStyle = .round
    curve.move(to: top); curve.curve(to: br, controlPoint1: CGPoint(x: s * 0.66, y: s * 0.78), controlPoint2: CGPoint(x: s * 0.66, y: s * 0.66))
    curve.curve(to: bot, controlPoint1: CGPoint(x: s * 0.66, y: s * 0.34), controlPoint2: CGPoint(x: s * 0.66, y: s * 0.22)); curve.stroke()
    for p in [top, mid, bot, br] {
        let r = s * 0.065
        let dot = NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        white.setFill(); dot.fill()
        NSColor(red: 0.3, green: 0.3, blue: 0.9, alpha: 1).setStroke(); dot.lineWidth = s * 0.012; dot.stroke(); white.setStroke()
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run(); p.waitUntilExit()
print("wrote \(out.path)")
