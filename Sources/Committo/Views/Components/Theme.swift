import SwiftUI
import CommittoCore

enum Theme {
    static let accent = Color(red: 0.42, green: 0.36, blue: 1.0)
    static let accent2 = Color(red: 0.0, green: 0.78, blue: 0.85)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let lanes: [Color] = [.indigo, .teal, .orange, .pink, .green, .purple, .yellow, .cyan, .red, .mint]
    static func lane(_ i: Int) -> Color { lanes[i % lanes.count] }
    static let added = Color.green, removed = Color.red
    static func color(_ s: Severity) -> Color { [Color.gray, .blue, .yellow, .orange, .red][s.rawValue] }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

struct Chip: View {
    let text: String; var symbol: String? = nil; var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 3) { if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }; Text(text).font(.system(size: 10, weight: .medium, design: .rounded)) }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule()).foregroundStyle(tint)
    }
}

struct SyncBadge: View {
    let ahead: Int, behind: Int
    var body: some View {
        HStack(spacing: 4) {
            if ahead > 0 { Chip(text: "\(ahead)", symbol: "arrow.up", tint: .green) }
            if behind > 0 { Chip(text: "\(behind)", symbol: "arrow.down", tint: .orange) }
        }
    }
}

struct PulseDot: View {
    @State private var on = false
    var color: Color = .green
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(on ? 2.2 : 1).opacity(on ? 0 : 0.9))
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
    }
}

struct IconButton: View {
    let symbol: String; let help: String; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
                .background(hover ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

struct EmptyState: View {
    let symbol: String, title: String, message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(Theme.gradient)
            Text(title).font(.headline); Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Date {
    var relative: String { RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date()) }
}
