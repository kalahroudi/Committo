import SwiftUI
import CommittoCore

struct ChangesView: View {
    @Environment(AppModel.self) var model
    @State private var selected: FileChange?
    @State private var diff: FileDiff?
    @State private var message = ""
    @State private var amend = false
    @State private var generating = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { selected?.id }, set: { id in selected = model.status.changes.first { $0.id == id } })) {
                    fileSection("Staged", model.status.staged, staged: true)
                    fileSection("Changes", model.status.unstaged, staged: false)
                }.listStyle(.inset)
                commitBox
            }.frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            Group {
                if let diff { DiffView(diff: diff, staged: selected?.staged ?? false) { Task { await load() } } }
                else { EmptyState(symbol: "doc.text.magnifyingglass", title: model.status.isClean ? "Working tree clean" : "Select a file", message: model.status.isClean ? "Nothing to commit." : "Pick a change to see its diff.") }
            }.frame(minWidth: 400)
        }
        .onChange(of: selected) { _, _ in Task { await load() } }
        .onChange(of: model.status.changes.count) { _, _ in Task { await load() } }
    }

    @ViewBuilder func fileSection(_ title: String, _ files: [FileChange], staged: Bool) -> some View {
        if !files.isEmpty {
            SwiftUI.Section {
                ForEach(files) { f in
                    HStack(spacing: 8) {
                        Text(f.kind.rawValue == "?" ? "U" : f.kind.rawValue).font(.system(size: 10, weight: .bold, design: .monospaced)).frame(width: 16, height: 16)
                            .background(color(f.kind).opacity(0.2), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(color(f.kind))
                        VStack(alignment: .leading, spacing: 0) {
                            Text((f.path as NSString).lastPathComponent).lineLimit(1)
                            Text((f.path as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        IconButton(symbol: staged ? "minus.circle" : "plus.circle", help: staged ? "Unstage" : "Stage") {
                            model.perform(staged ? "Unstaging" : "Staging") { staged ? try await $0.unstage([f.path]) : try await $0.stage([f.path]) }
                        }
                    }.tag(f.id)
                    .contextMenu {
                        if !staged { Button("Discard changes", role: .destructive) { model.perform("Discarding") { try await $0.discard([f.path], untracked: f.kind == .untracked) } } }
                        Button("Ignore…") { try? model.current?.gitignoreAdd(f.path); Task { await model.refresh() } }
                        Button("Reveal in Finder") { if let r = model.current { model.reveal(r.url.appendingPathComponent(f.path)) } }
                    }
                }
            } header: {
                HStack { Text("\(title) · \(files.count)")
                    Spacer()
                    Button(staged ? "Unstage all" : "Stage all") { model.perform("Staging") { staged ? try await $0.unstage(files.map(\.path)) : try await $0.stageAll() } }.buttonStyle(.link).font(.caption) }
            }
        }
    }

    var commitBox: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                TextEditor(text: $message).font(.system(size: 13)).frame(height: 84).scrollContentBackground(.hidden)
                    .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                Button { generate() } label: { if generating { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") } }
                    .buttonStyle(.plain).padding(8).help("Write commit message with \(model.agent?.displayName ?? "an agent")").disabled(model.status.staged.isEmpty || model.agent == nil)
            }
            HStack {
                Toggle("Amend", isOn: $amend).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Button { let m = message; model.perform("Committing") { try await $0.commit(m, amend: amend) }; message = ""; amend = false } label: {
                    Label("Commit", systemImage: "checkmark.circle.fill") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.status.staged.isEmpty && !amend))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(10).background(.bar)
    }

    func generate() {
        guard let agent = model.agent, let repo = model.current else { return }
        generating = true
        Task {
            defer { generating = false }
            let d = (try? await Shell.check("git", ["diff", "--cached"], cwd: repo.url)) ?? ""
            let prompt = "Write a concise Conventional Commits message (subject ≤72 chars, optional short body) for this staged diff. Output only the message, no code fences.\n\n\(d.prefix(30_000))"
            if let r = try? await agent.complete(AgentTask(prompt: prompt, workingDirectory: repo.url, maxTurns: 1)) { message = r.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    func load() async {
        guard let f = selected, let repo = model.current else { diff = nil; return }
        if f.kind == .untracked { diff = repo.untrackedContent(f.path); return }
        diff = try? await repo.diff(path: f.path, staged: f.staged).first
    }
    func color(_ k: ChangeKind) -> Color { switch k { case .added, .untracked: .green; case .deleted: .red; case .renamed, .copied: .blue; case .conflicted: .orange; default: .yellow } }
}

struct DiffView: View {
    @Environment(AppModel.self) var model
    let diff: FileDiff, staged: Bool, onChange: () -> Void

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                HStack { Text(diff.path).font(.system(.headline, design: .monospaced)); Spacer()
                    Text("+\(diff.additions)").foregroundStyle(.green); Text("−\(diff.deletions)").foregroundStyle(.red) }
                if diff.isBinary { Text("Binary file").foregroundStyle(.secondary) }
                ForEach(diff.hunks) { h in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text(h.header).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary); Spacer()
                            if !h.patch.isEmpty { Button(staged ? "Unstage hunk" : "Stage hunk") { apply(h) }.buttonStyle(.link).font(.caption) } }
                            .padding(.horizontal, 8).padding(.vertical, 4).background(Color.blue.opacity(0.1))
                        ForEach(h.lines) { l in
                            HStack(spacing: 0) {
                                Text(l.oldLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.tertiary)
                                Text(l.newLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.tertiary)
                                Text(prefix(l.kind) + l.text).padding(.leading, 8).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: 12, design: .monospaced)).background(bg(l.kind))
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.07)))
                }
            }.padding(16).frame(minWidth: 600, alignment: .leading)
        }
    }
    func prefix(_ k: DiffLine.Kind) -> String { k == .added ? "+" : k == .removed ? "-" : " " }
    func bg(_ k: DiffLine.Kind) -> Color { k == .added ? .green.opacity(0.14) : k == .removed ? .red.opacity(0.14) : .clear }
    func apply(_ h: DiffHunk) {
        let patch = diff.header + "\n" + h.patch
        model.perform(staged ? "Unstaging hunk" : "Staging hunk") { try await $0.applyPatch(patch, reverse: staged) }
        onChange()
    }
}
