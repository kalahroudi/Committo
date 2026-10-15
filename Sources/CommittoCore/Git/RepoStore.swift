import Foundation

public struct RecentRepo: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public var lastOpened: Date
    public var pinned: Bool = false
    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
}

public struct RepoSummary: Identifiable, Sendable {
    public var id: String { repo.id }
    public let repo: GitRepository
    public var branch: String
    public var dirty: Int
    public var ahead: Int
    public var behind: Int
    public var lastActivity: Date?
}

/// Persists recents and discovers repos on disk. Shared by the app and the MCP server.
public final class RepoStore: @unchecked Sendable {
    public static let shared = RepoStore()
    private let lock = NSLock()
    private let file: URL
    private var recents: [RecentRepo] = []

    public static var supportDirectory: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Committo")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    public init(file: URL = RepoStore.supportDirectory.appendingPathComponent("recents.json")) {
        self.file = file
        if let d = try? Data(contentsOf: file), let r = try? JSONDecoder().decode([RecentRepo].self, from: d) { recents = r }
    }

    public func all() -> [RecentRepo] {
        lock.lock(); defer { lock.unlock() }
        return recents.sorted { ($0.pinned ? 1 : 0, $0.lastOpened) > ($1.pinned ? 1 : 0, $1.lastOpened) }
    }
    public func touch(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if let i = recents.firstIndex(where: { $0.path == url.path }) { recents[i].lastOpened = Date() }
        else { recents.append(RecentRepo(path: url.path, lastOpened: Date())) }
        save()
    }
    public func togglePin(_ r: RecentRepo) {
        lock.lock(); defer { lock.unlock() }
        if let i = recents.firstIndex(where: { $0.path == r.path }) { recents[i].pinned.toggle(); save() }
    }
    public func remove(_ r: RecentRepo) { lock.lock(); recents.removeAll { $0.path == r.path }; save(); lock.unlock() }
    private func save() { try? JSONEncoder().encode(recents).write(to: file, options: .atomic) }

    /// Finds repos under common dev folders (depth-limited) and merges them in, ordered by recent .git activity.
    public func discover(roots: [URL]? = nil, maxDepth: Int = 3) -> [RecentRepo] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = roots ?? ["Developer", "Code", "code", "Projects", "projects", "src", "dev", "Documents/GitHub", "GitHub", "repos"].map { home.appendingPathComponent($0) }
        var found: [RecentRepo] = []
        let fm = FileManager.default
        func walk(_ dir: URL, depth: Int) {
            if GitRepository.isRepository(dir) {
                let head = dir.appendingPathComponent(".git/HEAD")
                let m = (try? fm.attributesOfItem(atPath: head.path)[.modificationDate] as? Date) ?? .distantPast
                found.append(RecentRepo(path: dir.path, lastOpened: m)); return
            }
            guard depth < maxDepth, let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for k in kids where (try? k.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if ["node_modules", "Pods", ".build", "build", "Library"].contains(k.lastPathComponent) { continue }
                walk(k, depth: depth + 1)
            }
        }
        for r in roots where fm.fileExists(atPath: r.path) { walk(r, depth: 0) }
        lock.lock()
        for f in found where !recents.contains(where: { $0.path == f.path }) { recents.append(f) }
        save(); lock.unlock()
        return all()
    }

    public func summary(_ r: RecentRepo) async -> RepoSummary? {
        let repo = GitRepository(url: r.url)
        guard let st = try? await repo.status() else { return nil }
        return RepoSummary(repo: repo, branch: st.branch, dirty: st.changes.count, ahead: st.ahead, behind: st.behind, lastActivity: await repo.headDate())
    }
}
