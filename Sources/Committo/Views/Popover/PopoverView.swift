import SwiftUI
import CommittoCore

struct PopoverView: View {
    @Environment(AppModel.self) var model
    @State private var query = ""
    @State private var showClone = false
    @State private var cloneURL = ""

    var filtered: [RepoSummary] {
        query.isEmpty ? model.recents : model.recents.filter { $0.repo.name.localizedCaseInsensitiveContains(query) || $0.branch.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    quickActions
                    if model.lens.contains(where: \.isLive) || !model.lens.isEmpty { lensStrip }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RECENT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.horizontal, 4)
                        if filtered.isEmpty {
                            Text(query.isEmpty ? "No repositories yet — open or clone one." : "No matches").font(.callout).foregroundStyle(.secondary).padding(.vertical, 20).frame(maxWidth: .infinity)
                        }
                        ForEach(filtered) { RepoRow(summary: $0) }
                    }
                }.padding(14)
            }
            footer
        }
        .frame(width: 400, height: 560)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showClone) { cloneSheet }
    }

    var header: some View {
        HStack(spacing: 10) {
            ZStack { RoundedRectangle(cornerRadius: 8).fill(Theme.gradient); Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.white).font(.system(size: 13, weight: .bold)) }.frame(width: 28, height: 28)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to repo or branch", text: $query).textFieldStyle(.plain)
            }.padding(.horizontal, 10).padding(.vertical, 7).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if model.busy { ProgressView().controlSize(.small) }
        }.padding(14).padding(.bottom, -4)
    }

    var quickActions: some View {
        let items: [(String, String, () -> Void)] = [
            ("Open", "folder", { model.pickFolderAndOpen() }),
            ("Clone", "square.and.arrow.down", { showClone = true }),
            ("Fetch all", "arrow.triangle.2.circlepath", { model.fetchAll() }),
            ("Lens", "eye.circle", { model.pane = .lens; model.openMainWindow?(); model.closePopover?() }),
            ("Scan", "lock.shield", { model.pane = .security; model.openMainWindow?(); model.closePopover?() }),
            ("CI", "gearshape.2", { model.pane = .ci; model.openMainWindow?(); model.closePopover?() }),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(items, id: \.0) { item in QuickTile(title: item.0, symbol: item.1, action: item.2) }
        }
    }

    var lensStrip: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Label("Agent Lens", systemImage: "eye.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent); Spacer()
                    Text(model.current?.name ?? "").font(.caption).foregroundStyle(.secondary) }
                ForEach(model.lens.prefix(3)) { item in
                    HStack(spacing: 8) {
                        if item.isLive { PulseDot() } else { Image(systemName: item.agent.symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 7) }
                        Text(item.branch).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("+\(item.additions)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.green)
                        Text("−\(item.deletions)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.red)
                    }
                }
            }
        }.onTapGesture { model.pane = .lens; model.openMainWindow?(); model.closePopover?() }
    }

    var footer: some View {
        HStack {
            Button { model.openMainWindow?(); model.closePopover?() } label: { Label("Open Committo", systemImage: "macwindow") }.buttonStyle(.plain)
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.plain)
        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
    }

    var cloneSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone repository").font(.headline)
            TextField("https://github.com/owner/repo.git", text: $cloneURL).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("Cancel") { showClone = false }
                Button("Clone to ~/Developer") {
                    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    model.clone(cloneURL, to: dir); showClone = false
                }.keyboardShortcut(.defaultAction).disabled(cloneURL.isEmpty) }
        }.padding(20).frame(width: 360)
    }
}

struct QuickTile: View {
    let title: String, symbol: String, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(hover ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.primary))
                Text(title).font(.system(size: 11, weight: .medium))
            }.frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(hover ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }.buttonStyle(.plain).onHover { hover = $0 }.animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct RepoRow: View {
    @Environment(AppModel.self) var model
    let summary: RepoSummary
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            ZStack { Circle().fill(Theme.accent.opacity(0.15)); Text(String(summary.repo.name.prefix(1)).uppercased()).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent) }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text(summary.repo.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if summary.dirty > 0 { Chip(text: "\(summary.dirty)", symbol: "pencil", tint: .orange) } }
                HStack(spacing: 6) { Image(systemName: "arrow.triangle.branch").font(.system(size: 9)); Text(summary.branch).lineLimit(1)
                    if let d = summary.lastActivity { Text("· \(d.relative)") } }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if hover {
                IconButton(symbol: "terminal", help: "Open in Terminal") { model.openTerminal(summary.repo.url) }
                IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") { model.openEditor(summary.repo.url) }
                IconButton(symbol: "folder", help: "Reveal in Finder") { model.reveal(summary.repo.url) }
            } else { SyncBadge(ahead: summary.ahead, behind: summary.behind) }
        }
        .padding(8).background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle()).onHover { hover = $0 }
        .onTapGesture { Task { await model.open(summary.repo.url, show: true) } }
    }
}
