#!/usr/bin/env swift
// Draws the Committo app icon ("Landing": a branch merging onto main under a HEAD ring) and writes AppIcon.icns.
// Geometry mirrors docs/assets/logo.svg (256-unit grid, y down).
// Usage: swift Scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px), u = s / 256
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: s - y * u) }
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * u, y: s - (y + h) * u, width: w * u, height: h * u) }
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let body = NSBezierPath(roundedRect: R(16, 16, 224, 224), xRadius: 54 * u, yRadius: 54 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3 * u), blur: 8 * u, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); body.fill()
    ctx.restoreGState()
    ctx.saveGState(); body.addClip()
    NSGradient(colors: [NSColor(red: 0.176, green: 0.153, blue: 0.4, alpha: 1), NSColor(red: 0.055, green: 0.051, blue: 0.11, alpha: 1)])!.draw(in: R(16, 16, 224, 224), angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.2), .clear])!.draw(in: R(16, 16, 224, 110), angle: -90)
    ctx.restoreGState()

    func stroke(_ path: NSBezierPath, _ color: NSColor, _ w: CGFloat) { color.setStroke(); path.lineWidth = w * u; path.lineCapStyle = .round; path.stroke() }
    func dot(_ c: CGPoint, _ r: CGFloat, fill: NSColor, ring: NSColor? = nil, ringW: CGFloat = 0) {
        let rect = CGRect(x: c.x - r * u, y: c.y - r * u, width: 2 * r * u, height: 2 * r * u)
        let o = NSBezierPath(ovalIn: rect); fill.setFill(); o.fill()
        if let ring { ring.setStroke(); o.lineWidth = ringW * u; o.stroke() }
    }
    let ink = NSColor(red: 0.078, green: 0.071, blue: 0.165, alpha: 1)
    let teal = NSColor(red: 0.098, green: 0.827, blue: 0.89, alpha: 1)
    let coral = NSColor(red: 1, green: 0.478, blue: 0.349, alpha: 1)

    let lane = NSBezierPath(); lane.move(to: P(156, 214)); lane.line(to: P(156, 64))
    stroke(lane, NSColor(red: 0.85, green: 0.83, blue: 1, alpha: 1), 16)
    let branch = NSBezierPath(); branch.move(to: P(90, 204))
    branch.curve(to: P(156, 120), controlPoint1: P(90, 152), controlPoint2: P(156, 172))
    stroke(branch, teal, 16)
    dot(P(90, 204), 14, fill: teal)
    dot(P(156, 60), 22 - 0, fill: ink, ring: .white, ringW: 12)
    dot(P(156, 124), 18, fill: coral, ring: ink, ringW: 6)
    img.unlockFocus()
    return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
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
