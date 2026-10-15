import SwiftUI
import CommittoCore

struct MainWindow: View {
    @Environment(AppModel.self) var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
        } detail: {
            ZStack {
                Group {
                    if model.current == nil { EmptyState(symbol: "folder.badge.plus", title: "Open a repository", message: "Pick one from the menu bar popover, or press ⌘O.") }
                    else {
                        switch model.pane {
                        case .changes: ChangesView()
                        case .history: HistoryView()
                        case .branches: BranchesView()
                        case .lens: LensView()
                        case .pulls: PullRequestsView()
                        case .security: SecurityView()
                        case .ci: CIView()
                        case .insights: InsightsView()
                        case .reflog: ReflogView()
                        }
                    }
                }
                if model.busy {
                    VStack { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.busyLabel).font(.callout) }
                        .padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule()); Spacer() }.padding(.top, 8)
                }
            }
            .toolbar { ToolbarItemGroup {
                Button { model.showPalette = true } label: { Label("Command Palette", systemImage: "command") }.keyboardShortcut("k", modifiers: .command)
                Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.keyboardShortcut("z", modifiers: .command).help("Undo last history change (⌘Z)")
                Button { model.fetch() } label: { Label("Fetch", systemImage: "arrow.triangle.2.circlepath") }
                Button { model.pull() } label: { Label("Pull", systemImage: "arrow.down.to.line") }
                Button { model.push() } label: { Label("Push", systemImage: "arrow.up.to.line") }
            } }
        }
        .sheet(isPresented: $model.showPalette) { CommandPalette() }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task(id: model.current?.id) { await model.refresh() }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { Optional(model.pane) }, set: { if let p = $0 { model.pane = p } })) {
            Menu {
                ForEach(model.recents) { s in Button(s.repo.name) { Task { await model.open(s.repo.url) } } }
                Divider(); Button("Open…") { model.pickFolderAndOpen() }
            } label: {
                HStack { Image(systemName: "shippingbox.fill").foregroundStyle(Theme.gradient)
                    VStack(alignment: .leading) { Text(model.current?.name ?? "No repository").font(.headline)
                        if model.current != nil { Text("\(model.status.branch)").font(.caption).foregroundStyle(.secondary) } }
                    Spacer(); SyncBadge(ahead: model.status.ahead, behind: model.status.behind) }
            }.menuStyle(.borderlessButton).padding(.vertical, 4)

            SwiftUI.Section("Work") { row(.changes, badge: model.status.changes.count); row(.history); row(.branches) }
            SwiftUI.Section("Agents") { row(.lens, badge: model.lens.filter(\.isLive).count); row(.pulls) }
            SwiftUI.Section("Quality") { row(.security); row(.ci) }
            SwiftUI.Section("Explore") { row(.insights); row(.reflog) }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        .listStyle(.sidebar)
    }
    func row(_ p: Pane, badge: Int = 0) -> some View {
        Label(p.rawValue, systemImage: p.symbol).tag(p).badge(badge)
    }
}

struct PaletteAction: Identifiable { let id = UUID(); let title: String; let symbol: String; let run: @MainActor (AppModel) -> Void }

/// ⌘K — one place to do anything, for people who'd rather type than remember where things live.
struct CommandPalette: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var q = ""
    @FocusState private var focused: Bool

    var actions: [PaletteAction] {
        var a: [PaletteAction] = Pane.allCases.map { p in PaletteAction(title: "Go to \(p.rawValue)", symbol: p.symbol) { $0.pane = p } }
        a += [
            .init(title: "Fetch", symbol: "arrow.triangle.2.circlepath") { $0.fetch() },
            .init(title: "Pull", symbol: "arrow.down.to.line") { $0.pull() },
            .init(title: "Push", symbol: "arrow.up.to.line") { $0.push() },
            .init(title: "Undo last action", symbol: "arrow.uturn.backward") { $0.undo() },
            .init(title: "Stage all changes", symbol: "plus.circle") { $0.perform("Staging") { try await $0.stageAll() } },
            .init(title: "Stash changes", symbol: "tray.and.arrow.down") { $0.perform("Stashing") { try await $0.stashPush() } },
            .init(title: "Open repository…", symbol: "folder") { $0.pickFolderAndOpen() },
            .init(title: "Open on web", symbol: "safari") { $0.openOnWeb() },
            .init(title: "Open in editor", symbol: "chevron.left.forwardslash.chevron.right") { m in if let u = m.current?.url { m.openEditor(u) } },
            .init(title: "Open in Terminal", symbol: "terminal") { m in if let u = m.current?.url { m.openTerminal(u) } },
        ]
        a += model.branches.filter { !$0.isRemote && !$0.isCurrent }.map { b in PaletteAction(title: "Switch to \(b.name)", symbol: "arrow.triangle.branch") { m in m.perform("Switching") { try await $0.checkout(b.name) } } }
        a += model.recents.map { s in PaletteAction(title: "Open \(s.repo.name)", symbol: "shippingbox") { m in Task { await m.open(s.repo.url) } } }
        return q.isEmpty ? a : a.filter { $0.title.localizedCaseInsensitiveContains(q) || fuzzy(q, $0.title) }
    }
    func fuzzy(_ needle: String, _ hay: String) -> Bool {
        var it = hay.lowercased().makeIterator()
        return needle.lowercased().allSatisfy { ch in while let c = it.next() { if c == ch { return true } }; return false }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "command").foregroundStyle(Theme.gradient); TextField("Type a command…", text: $q).textFieldStyle(.plain).font(.title3).focused($focused).onSubmit { run(actions.first) } }.padding(14)
            Divider()
            List(actions.prefix(12)) { a in
                Button { run(a) } label: { Label(a.title, systemImage: a.symbol).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
            }.listStyle(.plain)
        }.frame(width: 520, height: 400).onAppear { focused = true }
    }
    func run(_ a: PaletteAction?) { guard let a else { return }; dismiss(); a.run(model) }
}
