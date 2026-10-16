import SwiftUI

/// The approved Committo logo ("Landing"), mirroring docs/assets/logo.svg on its 256-unit grid.
struct CommittoLogo: View {
    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 256
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }
            func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (x - r) * u, y: (y - r) * u, width: 2 * r * u, height: 2 * r * u))
            }
            let ink = Color(red: 0.078, green: 0.071, blue: 0.165)
            let teal = Color(red: 0.098, green: 0.827, blue: 0.89)
            let coral = Color(red: 1, green: 0.478, blue: 0.349)
            let body = Path(roundedRect: CGRect(x: 16 * u, y: 16 * u, width: 224 * u, height: 224 * u), cornerRadius: 54 * u)
            ctx.fill(body, with: .linearGradient(
                Gradient(colors: [Color(red: 0.176, green: 0.153, blue: 0.4), Color(red: 0.055, green: 0.051, blue: 0.11)]),
                startPoint: P(0, 16), endPoint: P(0, 240)))
            ctx.drawLayer { l in
                l.clip(to: body)
                l.fill(Path(CGRect(x: 16 * u, y: 16 * u, width: 224 * u, height: 110 * u)), with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.2), .white.opacity(0)]), startPoint: P(0, 16), endPoint: P(0, 126)))
            }
            let round = StrokeStyle(lineWidth: 16 * u, lineCap: .round)
            var lane = Path(); lane.move(to: P(156, 214)); lane.addLine(to: P(156, 64))
            ctx.stroke(lane, with: .linearGradient(Gradient(colors: [.white, Color(red: 0.725, green: 0.694, blue: 1)]),
                                                   startPoint: P(0, 64), endPoint: P(0, 214)), style: round)
            var branch = Path(); branch.move(to: P(90, 204))
            branch.addCurve(to: P(156, 120), control1: P(90, 152), control2: P(156, 172))
            ctx.stroke(branch, with: .color(teal), style: round)
            ctx.fill(disc(90, 204, 14), with: .color(teal))
            ctx.fill(disc(156, 60, 22), with: .color(ink))
            ctx.stroke(disc(156, 60, 22), with: .color(.white), lineWidth: 12 * u)
            ctx.fill(disc(156, 124, 18), with: .color(coral))
            ctx.stroke(disc(156, 124, 18), with: .color(ink), lineWidth: 6 * u)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Committo")
    }
}
