import SwiftUI
import Charts
import CommittoCore

struct InsightsView: View {
    @Environment(AppModel.self) var model
    @State private var days: [Date: Int] = [:]
    @State private var people: [(name: String, commits: Int)] = []
    @State private var hot: [(path: String, changes: Int)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Insights").font(.title2.bold())
                Card { VStack(alignment: .leading) { Text("Activity · last year").font(.headline); Heatmap(counts: days) } }
                HStack(alignment: .top, spacing: 16) {
                    Card { VStack(alignment: .leading) { Text("Contributors").font(.headline)
                        Chart(people.prefix(8), id: \.name) { BarMark(x: .value("Commits", $0.commits), y: .value("Who", $0.name)).foregroundStyle(Theme.gradient).cornerRadius(4) }
                            .frame(height: 220) } }
                    Card { VStack(alignment: .leading) { Text("Churn hotspots · 6 months").font(.headline)
                        Chart(hot.prefix(8), id: \.path) { BarMark(x: .value("Changes", $0.changes), y: .value("File", ($0.path as NSString).lastPathComponent)).foregroundStyle(.orange.gradient).cornerRadius(4) }
                            .frame(height: 220) } }
                }
            }.padding(18)
        }.task(id: model.current?.id) {
            guard let r = model.current else { return }
            days = (try? await r.commitCountsByDay()) ?? [:]; people = (try? await r.contributors()) ?? []; hot = (try? await r.hotspots()) ?? []
        }
    }
}

/// GitHub-style contribution calendar drawn with Canvas.
struct Heatmap: View {
    let counts: [Date: Int]
    var body: some View {
        Canvas { ctx, size in
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let weeks = 53, cell: CGFloat = min(size.width / CGFloat(weeks), 14), gap: CGFloat = 3
            let maxV = max(counts.values.max() ?? 1, 1)
            let start = cal.date(byAdding: .day, value: -(weeks * 7 - 1) - 0, to: today)!
            let offset = cal.component(.weekday, from: start) - 1
            for i in 0..<(weeks * 7) {
                guard let d = cal.date(byAdding: .day, value: i, to: start), d <= today else { continue }
                let idx = i + offset, col = idx / 7, row = idx % 7
                let v = counts[d] ?? 0
                let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell - gap, height: cell - gap)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(v == 0 ? Color.primary.opacity(0.07) : Theme.accent.opacity(0.25 + 0.75 * Double(v) / Double(maxV))))
            }
        }.frame(height: 7 * 14 + 4)
    }
}
