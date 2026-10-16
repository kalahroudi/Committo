import SwiftUI
import Charts
import CommittoCore

struct ConsoleLine: Identifiable { let id = UUID(); enum Kind { case text, tool, result, done }; let kind: Kind; let text: String }

@MainActor @Observable
final class AgentRunModel {
    var lines: [ConsoleLine] = []
    var running = false
    var cost: Double?
    private var task: Task<Void, Never>?

    func start(agent: AgentBackend, prompt: String, repo: GitRepository, isolate: Bool, readOnly: Bool, onDone: @escaping () -> Void) {
        lines = []; running = true; cost = nil
        task = Task {
            var dir = repo.url
            do {
                if isolate {
                    let slug = prompt.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(4).joined(separator: "-")
                    let branch = "\(agent.kind == .human ? "agent" : agent.kind.rawValue)/\(slug.isEmpty ? "task" : slug)-\(Int(Date().timeIntervalSince1970) % 10000)"
                    let path = repo.url.deletingLastPathComponent().appendingPathComponent("\(repo.name)-\(branch.replacingOccurrences(of: "/", with: "-"))").path
                    try await repo.addWorktree(path: path, branch: branch)
                    dir = URL(fileURLWithPath: path)
                    lines.append(.init(kind: .tool, text: "worktree → \(path)"))
                }
                for try await e in agent.run(AgentTask(prompt: prompt, workingDirectory: dir, readOnly: readOnly)) {
                    switch e {
                    case .text(let t): lines.append(.init(kind: .text, text: t))
                    case .toolUse(let n, let s): lines.append(.init(kind: .tool, text: "\(n)  \(s)"))
                    case .toolResult(let r): lines.append(.init(kind: .result, text: r))
                    case .finished(let r): cost = r.costUSD; lines.append(.init(kind: .done, text: "Finished" + (r.costUSD.map { String(format: " · $%.3f", $0) } ?? "")))
                    }
                }
            } catch { lines.append(.init(kind: .done, text: "Error: \(error.localizedDescription)")) }
            running = false; onDone()
        }
    }
    func cancel() { task?.cancel(); running = false }
}

struct LensView: View {
    @Environment(AppModel.self) var model
    @State private var runModel = AgentRunModel()
    @State private var prompt = ""
    @State private var isolate = true
    @State private var readOnly = false
    @State private var selected: AgentWorkItem?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    dispatchCard
                    summaryChart
                    if model.lens.isEmpty {
                        EmptyState(symbol: "eye.circle", title: "No agent work yet", message: "Branches and worktrees created by Claude, Codex, Cursor, Copilot, Aider and friends show up here, with live status.")
                    }
                    ForEach(model.lens) { item in WorkCard(item: item, selected: selected?.id == item.id).onTapGesture { selected = item } }
                }.padding(16)
            }.frame(minWidth: 460)
            Group {
                if runModel.lines.isEmpty && selected == nil { EmptyState(symbol: "terminal", title: "Agent console", message: "Dispatch a task to watch tool calls stream in live.") }
                else if !runModel.lines.isEmpty || runModel.running { console }
                else if let s = selected { WorkDetail(item: s) }
            }.frame(minWidth: 320)
        }
    }

    var dispatchCard: some View {
        @Bindable var model = model
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Dispatch an agent", systemImage: "paperplane.fill").font(.headline)
                TextField("What should it do? e.g. “add dark mode toggle to settings”", text: $prompt, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("", selection: $model.selectedAgentID) {
                        ForEach(model.registry.backends, id: \.id) { b in Text(b.displayName + (b.isAvailable ? "" : " (not found)")).tag(b.id) }
                    }.labelsHidden().frame(maxWidth: 220)
                    Toggle("Own worktree", isOn: $isolate).toggleStyle(.checkbox).help("Run in a fresh git worktree + branch so your working copy is untouched")
                    Toggle("Read-only", isOn: $readOnly).toggleStyle(.checkbox)
                    Spacer()
                    if runModel.running { Button("Stop", role: .destructive) { runModel.cancel() } }
                    else {
                        Button { go() } label: { Label("Run", systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(prompt.isEmpty || model.agent == nil).keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
        }
    }

    @ViewBuilder var summaryChart: some View {
        let counts = Dictionary(grouping: model.lens, by: \.agent).map { (agent: $0.key, commits: $0.value.reduce(0) { $0 + $1.commits.count }) }
        if counts.count > 0 {
            Card {
                VStack(alignment: .leading) {
                    Text("Commits by author type").font(.subheadline.weight(.semibold))
                    Chart(counts, id: \.agent) { BarMark(x: .value("Commits", $0.commits), y: .value("Agent", $0.agent.displayName)).foregroundStyle(Theme.gradient).cornerRadius(4) }
                        .frame(height: CGFloat(counts.count) * 28 + 20)
                }
            }
        }
    }

    var console: some View {
        VStack(spacing: 0) {
            HStack { if runModel.running { ProgressView().controlSize(.small) }; Text(runModel.running ? "Running…" : "Done").font(.headline); Spacer()
                Button("Clear") { runModel.lines = [] }.buttonStyle(.link).disabled(runModel.running) }.padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(runModel.lines) { l in
                            switch l.kind {
                            case .text: Text(l.text).textSelection(.enabled).font(.system(size: 13))
                            case .tool: Label(l.text, systemImage: "wrench.and.screwdriver").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent2).lineLimit(2)
                            case .result: Text(l.text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(3)
                            case .done: Label(l.text, systemImage: "checkmark.seal").font(.callout.weight(.semibold)).foregroundStyle(.green)
                            }
                        }.id("end")
                    }.padding(12)
                }.onChange(of: runModel.lines.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    func go() {
        guard let a = model.agent, let r = model.current else { return }
        runModel.start(agent: a, prompt: prompt, repo: r, isolate: isolate, readOnly: readOnly) { Task { await model.refresh() } }
    }
}

struct WorkCard: View {
    let item: AgentWorkItem, selected: Bool
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ZStack { Circle().fill(Theme.accent.opacity(0.15)); Image(systemName: item.agent.symbol).font(.system(size: 13)).foregroundStyle(Theme.accent) }.frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) { Text(item.branch).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(item.agent.displayName) · \(item.lastActivity.relative)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if item.isLive { HStack(spacing: 5) { PulseDot(); Text("working").font(.caption).foregroundStyle(.green) } }
                    else if item.dirtyFiles > 0 { Chip(text: "\(item.dirtyFiles) uncommitted", tint: .orange) }
                }
                // Commit timeline
                HStack(spacing: 3) { ForEach(item.commits.prefix(24).reversed()) { c in Circle().fill(Theme.accent.opacity(0.7)).frame(width: 7, height: 7).help(c.subject) }
                    if item.commits.count > 24 { Text("+\(item.commits.count - 24)").font(.caption2).foregroundStyle(.secondary) } }
                HStack(spacing: 10) {
                    Label("\(item.commits.count)", systemImage: "circle.fill").font(.caption)
                    Label("\(item.filesChanged) files", systemImage: "doc").font(.caption)
                    ChurnBar(adds: item.additions, dels: item.deletions)
                }.foregroundStyle(.secondary)
            }
        }.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, lineWidth: selected ? 1.5 : 0))
    }
}

struct ChurnBar: View {
    let adds: Int, dels: Int
    var body: some View {
        let total = max(adds + dels, 1)
        HStack(spacing: 6) {
            Text("+\(adds)").foregroundStyle(.green); Text("−\(dels)").foregroundStyle(.red)
            GeometryReader { g in HStack(spacing: 1) { Rectangle().fill(Color.green).frame(width: g.size.width * CGFloat(adds) / CGFloat(total)); Rectangle().fill(Color.red) } }
                .frame(width: 80, height: 5).clipShape(Capsule())
        }.font(.system(size: 11, design: .monospaced))
    }
}

struct WorkDetail: View {
    @Environment(AppModel.self) var model
    let item: AgentWorkItem
    @State private var review = ""
    @State private var reviewing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.branch).font(.title3.bold())
                HStack {
                    if let w = item.worktree { Button("Open worktree") { Task { await model.open(URL(fileURLWithPath: w)) } } }
                    Button("Switch to branch") { model.perform("Switching") { try await $0.checkout(item.branch) } }
                    Button { runReview() } label: { Label(reviewing ? "Reviewing…" : "Agent review", systemImage: "sparkles") }.disabled(reviewing || model.agent == nil)
                    Button("Merge") { model.perform("Merging") { try await $0.merge(item.branch) } }
                }
                if !review.isEmpty { Card { Text(LocalizedStringKey(review)).textSelection(.enabled) } }
                Text("Commits").font(.headline)
                ForEach(item.commits) { c in HStack { Text(c.shortHash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary); Text(c.subject).lineLimit(1); Spacer(); Text(c.date.relative).font(.caption).foregroundStyle(.tertiary) } }
            }.padding(16)
        }
    }
    func runReview() {
        guard let agent = model.agent, let repo = model.current else { return }
        reviewing = true; review = ""
        Task {
            defer { reviewing = false }
            let base = await AgentLens.defaultBase(repo)
            let diff = (try? await repo.rawDiff(base: base, head: item.branch)) ?? ""
            let prompt = "Review this agent-written branch `\(item.branch)` against \(base). Flag bugs, security issues, missed edge cases, and unrelated changes. Be concise and cite files.\n\n```diff\n\(diff.prefix(60_000))\n```"
            do { review = try await agent.complete(AgentTask(prompt: prompt, workingDirectory: repo.url, maxTurns: 6)).text } catch { review = "Review failed: \(error.localizedDescription)" }
        }
    }
}
