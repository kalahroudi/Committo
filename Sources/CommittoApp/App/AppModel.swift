import SwiftUI
import AppKit
import CommittoCore

enum Pane: String, CaseIterable, Identifiable {
    case changes = "Changes", history = "History", branches = "Branches", lens = "Agent Lens", pulls = "Pull Requests"
    case security = "Security", ci = "CI Runners", insights = "Insights", reflog = "Time Machine"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .changes: "square.and.pencil"; case .history: "point.topleft.down.curvedto.point.bottomright.up"; case .branches: "arrow.triangle.branch"
        case .lens: "eye.circle"; case .pulls: "arrow.triangle.pull"; case .security: "lock.shield"; case .ci: "gearshape.2"
        case .insights: "chart.bar.xaxis"; case .reflog: "clock.arrow.circlepath"
        }
    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var recents: [RepoSummary] = []
    var current: GitRepository?
    var status = RepoStatus()
    var rows: [GraphRow] = []
    var branches: [Branch] = []
    var stashes: [Stash] = []
    var tags: [Tag] = []
    var worktrees: [Worktree] = []
    var lens: [AgentWorkItem] = []
    var reflog: [ReflogEntry] = []
    var pane: Pane = .changes
    var busy = false
    var busyLabel = ""
    var error: String?
    var showPalette = false
    var accounts: [Account] = AccountStore.shared.all()
    var registry = AgentRegistry()
    var selectedAgentID: String = UserDefaults.standard.string(forKey: "agentID") ?? "claude-code" { didSet { UserDefaults.standard.set(selectedAgentID, forKey: "agentID") } }
    var openMainWindow: (() -> Void)?
    var closePopover: (() -> Void)?
    var search = ""

    var agent: AgentBackend? { registry.backend(id: selectedAgentID).flatMap { $0.isAvailable ? $0 : nil } ?? registry.preferred }

    func bootstrap() async {
        // Directory walk is blocking file I/O; keep it off the main actor.
        await Task.detached(priority: .utility) { _ = RepoStore.shared.discover() }.value
        await refreshRecents()
        if current == nil, let first = recents.first { await open(first.repo.url) }
    }

    func refreshRecents() async {
        var out: [RepoSummary] = []
        for r in RepoStore.shared.all().prefix(12) { if let s = await RepoStore.shared.summary(r) { out.append(s) } }
        recents = out
    }

    func open(_ url: URL, show: Bool = false) async {
        RepoStore.shared.touch(url)
        current = GitRepository(url: url)
        await refresh()
        if show { openMainWindow?(); closePopover?() }
    }

    func refresh() async {
        guard let r = current else { return }
        async let st = try? r.status()
        async let log = try? r.log(limit: 400)
        async let br = try? r.branches()
        async let sh = try? r.stashes()
        async let tg = try? r.tags()
        async let wt = try? r.worktrees()
        async let rl = try? r.reflog()
        status = await st ?? status
        rows = CommitGraph.layout(await log ?? [])
        branches = await br ?? []; stashes = await sh ?? []; tags = await tg ?? []; worktrees = await wt ?? []; reflog = await rl ?? []
        lens = await AgentLens.scan(r)
    }

    /// Runs a git action with busy/error handling, then refreshes.
    func perform(_ label: String, _ work: @escaping (GitRepository) async throws -> Void) {
        guard let r = current else { return }
        Task {
            busy = true; busyLabel = label
            do { try await work(r) } catch { self.error = error.localizedDescription }
            busy = false
            await refresh(); await refreshRecents()
        }
    }

    func fetch() { perform("Fetching") { try await $0.fetch() } }
    func pull() { perform("Pulling") { try await $0.pull() } }
    func push() { perform("Pushing") { [status] r in try await r.push(setUpstream: status.upstream == nil) } }
    func undo() { perform("Undoing") { try await $0.undoLast() } }

    func fetchAll() {
        Task { busy = true; busyLabel = "Fetching all"
            for s in recents { try? await s.repo.fetch() }
            busy = false; await refreshRecents() }
    }

    // External tools
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openTerminal(_ url: URL) { NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration()) }
    func openEditor(_ url: URL) {
        Task { if let code = Shell.which("code") ?? Shell.which("cursor") { _ = try? await Shell.run(code, [url.path]) } else { NSWorkspace.shared.open(url) } }
    }
    func openOnWeb() {
        Task { guard let r = current, var u = await r.remoteURL() else { return }
            u = u.replacingOccurrences(of: "git@github.com:", with: "https://github.com/").replacingOccurrences(of: "git@gitlab.com:", with: "https://gitlab.com/").replacingOccurrences(of: ".git", with: "")
            if let url = URL(string: u) { NSWorkspace.shared.open(url) } }
    }
    func pickFolderAndOpen() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.message = "Choose a git repository"
        if p.runModal() == .OK, let u = p.url {
            if GitRepository.isRepository(u) { Task { await open(u, show: true) } } else { error = "\(u.lastPathComponent) is not a git repository" }
        }
    }
    func clone(_ remote: String, to parent: URL) {
        let name = remote.split(separator: "/").last.map { String($0).replacingOccurrences(of: ".git", with: "") } ?? "repo"
        let dest = parent.appendingPathComponent(name)
        Task { busy = true; busyLabel = "Cloning \(name)"
            do { for try await _ in GitRepository.clone(remote, into: dest) {}; await open(dest, show: true) } catch { self.error = error.localizedDescription }
            busy = false }
    }

    func copyToPasteboard(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}
