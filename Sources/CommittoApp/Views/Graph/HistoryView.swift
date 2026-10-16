import SwiftUI
import CommittoCore

struct HistoryView: View {
    @Environment(AppModel.self) var model
    @State private var selected: GraphRow?
    @State private var files: [FileDiff] = []
    @State private var filter = ""

    var rows: [GraphRow] {
        filter.isEmpty ? model.rows : model.rows.filter { $0.commit.subject.localizedCaseInsensitiveContains(filter) || $0.commit.author.localizedCaseInsensitiveContains(filter) || $0.commit.hash.hasPrefix(filter) }
    }
    var laneWidth: CGFloat { CGFloat(min(max(model.rows.map(\.laneCount).max() ?? 1, 1), 12)) * 16 + 12 }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Filter by message, author or hash", text: $filter).textFieldStyle(.plain) }.padding(10).background(.bar)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 0) {
                                GraphLane(row: row).frame(width: laneWidth, height: 30)
                                CommitLine(row: row, signature: model.signatures[row.commit.hash])
                            }.frame(height: 30)
                            .background(selected?.id == row.id ? Theme.accent.opacity(0.18) : .clear)
                            .contentShape(Rectangle()).onTapGesture { selected = row; Task { files = (try? await model.current?.show(row.commit.hash)) ?? [] } }
                            .contextMenu {
                                Button("Copy hash") { model.copyToPasteboard(row.commit.hash) }
                                Button("Cherry-pick") { model.perform("Cherry-picking") { try await $0.cherryPick(row.commit.hash) } }
                                Button("Revert") { model.perform("Reverting") { try await $0.revert(row.commit.hash) } }
                                Button("New branch here…") { model.perform("Branching") { try await $0.createBranch("branch-\(row.commit.shortHash)", from: row.commit.hash) } }
                                Button("Tag here") { model.perform("Tagging") { try await $0.tag("v-\(row.commit.shortHash)", at: row.commit.hash) } }
                                Divider()
                                Button("Reset (mixed) to here", role: .destructive) { model.perform("Resetting") { try await $0.reset(row.commit.hash) } }
                            }
                        }
                    }
                }
            }.frame(minHeight: 260)
            detail.frame(minHeight: 160, idealHeight: 280)
        }
    }

    @ViewBuilder var detail: some View {
        if let c = selected?.commit {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(c.subject).font(.headline); Spacer(); Chip(text: c.shortHash, tint: Theme.accent) }
                    HStack { Label(c.author, systemImage: "person"); Label(c.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        let kind = AgentKind.detect(author: c.author, email: c.email, coAuthors: c.coAuthors); if kind != .human { Chip(text: kind.displayName, symbol: kind.symbol, tint: Theme.accent2) } }
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(files) { f in
                        DisclosureGroup { DiffMini(diff: f) } label: { HStack { Text(f.path).font(.system(size: 12, design: .monospaced)); Spacer(); Text("+\(f.additions)").foregroundStyle(.green); Text("−\(f.deletions)").foregroundStyle(.red) }.font(.caption) }
                    }
                }.padding(14)
            }
        } else { EmptyState(symbol: "point.topleft.down.curvedto.point.bottomright.up", title: "Select a commit", message: "See its files and diffs here.") }
    }
}

struct DiffMini: View {
    let diff: FileDiff
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.hunks.flatMap(\.lines).prefix(200)) { l in
                Text((l.kind == .added ? "+" : l.kind == .removed ? "-" : " ") + l.text).font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).background(l.kind == .added ? Color.green.opacity(0.14) : l.kind == .removed ? Color.red.opacity(0.14) : .clear)
            }
        }
    }
}

struct CommitLine: View {
    let row: GraphRow
    var signature: SignatureInfo?
    var body: some View {
        HStack(spacing: 8) {
            ForEach(row.commit.refs.prefix(3), id: \.self) { r in
                Chip(text: r.replacingOccurrences(of: "HEAD -> ", with: ""), symbol: r.contains("HEAD") ? "location.fill" : r.hasPrefix("tag:") ? "tag" : "arrow.triangle.branch",
                     tint: r.contains("HEAD") ? Theme.accent : r.hasPrefix("tag:") ? .orange : .teal)
            }
            let kind = AgentKind.detect(author: row.commit.author, email: row.commit.email, coAuthors: row.commit.coAuthors)
            if kind != .human { Image(systemName: kind.symbol).font(.system(size: 10)).foregroundStyle(Theme.accent2).help(kind.displayName) }
            Text(row.commit.subject).font(.system(size: 13)).lineLimit(1)
            if let sig = signature, sig.status.isSigned {
                Image(systemName: sig.status.isVerified ? "checkmark.seal.fill" : "exclamationmark.seal")
                    .font(.system(size: 11)).foregroundStyle(sig.status.isVerified ? .green : .orange)
                    .help(sig.status.isVerified ? "Verified signature\(sig.signer.map { " from \($0)" } ?? "")" : "Signed, but not verified (\(sig.status))")
            }
            Spacer(minLength: 8)
            Text(row.commit.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(row.commit.date.relative).font(.caption).foregroundStyle(.tertiary).frame(width: 90, alignment: .trailing)
            Text(row.commit.shortHash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }.padding(.trailing, 12)
    }
}

/// Draws one row of the commit graph from `CommitGraph.segments`.
struct GraphLane: View {
    let row: GraphRow
    var body: some View {
        Canvas { ctx, size in
            let lw: CGFloat = 16
            func x(_ l: Int) -> CGFloat { CGFloat(l) * lw + 14 }
            func y(_ v: Double) -> CGFloat { CGFloat(v) * size.height }
            for s in CommitGraph.segments(for: row) {
                var p = Path()
                p.move(to: CGPoint(x: x(s.x0), y: y(s.y0)))
                if s.x0 == s.x1 { p.addLine(to: CGPoint(x: x(s.x1), y: y(s.y1))) }
                else { p.addCurve(to: CGPoint(x: x(s.x1), y: y(s.y1)), control1: CGPoint(x: x(s.x0), y: y((s.y0 + s.y1) / 2)), control2: CGPoint(x: x(s.x1), y: y((s.y0 + s.y1) / 2))) }
                ctx.stroke(p, with: .color(Theme.lane(s.lane)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            let c = CGPoint(x: x(row.nodeLane), y: size.height / 2)
            let r: CGFloat = row.commit.isMerge ? 4 : 5
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(Theme.lane(row.nodeLane)))
            ctx.stroke(dot, with: .color(.black.opacity(0.35)), lineWidth: 1)
            if row.commit.isMerge { ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), with: .color(.white)) }
        }
    }
}
