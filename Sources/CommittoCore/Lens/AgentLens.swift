import Foundation

/// Who did the work. Detected from branch prefixes, commit trailers and author names.
public enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claude, codex, cursor, copilot, gemini, aider, commandCode, devin, other, human
    public var displayName: String {
        switch self {
        case .claude: "Claude Code"; case .codex: "Codex"; case .cursor: "Cursor"; case .copilot: "Copilot"
        case .gemini: "Gemini"; case .aider: "Aider"; case .commandCode: "Command Code"; case .devin: "Devin"
        case .other: "Agent"; case .human: "Human"
        }
    }
    public var symbol: String {
        switch self {
        case .claude: "sparkle"; case .codex: "terminal"; case .cursor: "cursorarrow.rays"; case .copilot: "airplane"
        case .gemini: "diamond"; case .aider: "person.2.wave.2"; case .commandCode: "command"; case .devin: "cpu"
        case .other: "wand.and.stars"; case .human: "person.fill"
        }
    }

    public static func detect(branch: String? = nil, author: String = "", email: String = "", coAuthors: [String] = [], message: String = "") -> AgentKind {
        let hay = ([author, email, message] + coAuthors).joined(separator: " ").lowercased()
        let b = (branch ?? "").lowercased()
        let table: [(AgentKind, [String])] = [
            (.claude, ["claude/", "claude-"]), (.codex, ["codex/"]), (.cursor, ["cursor/"]), (.copilot, ["copilot/"]),
            (.gemini, ["gemini/"]), (.aider, ["aider/"]), (.commandCode, ["commandcode/", "cmd/"]), (.devin, ["devin/"]),
        ]
        for (k, prefixes) in table where prefixes.contains(where: { b.hasPrefix($0) }) { return k }
        if hay.contains("claude") || hay.contains("anthropic.com") { return .claude }
        if hay.contains("codex") || hay.contains("openai") { return .codex }
        if hay.contains("cursoragent") || hay.contains("cursor agent") { return .cursor }
        if hay.contains("copilot") { return .copilot }
        if hay.contains("gemini") { return .gemini }
        if hay.contains("aider") { return .aider }
        if hay.contains("command code") || hay.contains("commandcode") { return .commandCode }
        if hay.contains("devin") { return .devin }
        if hay.contains("[bot]") { return .other }
        return .human
    }
}

public struct AgentWorkItem: Identifiable, Sendable {
    public var id: String { branch + (worktree ?? "") }
    public let agent: AgentKind
    public let branch: String
    public let worktree: String?
    public let commits: [Commit]
    public let filesChanged: Int
    public let additions: Int
    public let deletions: Int
    public let lastActivity: Date
    public let dirtyFiles: Int
    public var isLive: Bool { dirtyFiles > 0 && Date().timeIntervalSince(lastActivity) < 15 * 60 }
}

/// Builds the "Lens": a cross-branch/worktree view of everything agents are doing in a repo.
public enum AgentLens {
    public static func scan(_ repo: GitRepository, base baseOverride: String? = nil, limit: Int = 30) async -> [AgentWorkItem] {
        let base: String
        if let b = baseOverride { base = b } else { base = await defaultBase(repo) }
        let worktrees = (try? await repo.worktrees()) ?? []
        var wtByBranch: [String: String] = [:]
        for w in worktrees { if let b = w.branch { wtByBranch[b] = w.path } }
        let branches = ((try? await repo.branches()) ?? []).filter { !$0.isRemote && $0.name != base }
            .sorted { $0.lastCommit > $1.lastCommit }.prefix(limit)
        var items: [AgentWorkItem] = []
        for b in branches {
            let commits = (try? await repo.log(limit: 50, all: false, ref: "\(base)..\(b.name)")) ?? []
            guard !commits.isEmpty else { continue }
            let agent = commits.lazy.map { AgentKind.detect(branch: b.name, author: $0.author, email: $0.email, coAuthors: $0.coAuthors, message: $0.subject) }.first { $0 != .human } ?? .human
            let stat = (try? await Shell.check("git", ["diff", "--numstat", "\(base)...\(b.name)"], cwd: repo.url)) ?? ""
            var adds = 0, dels = 0, files = 0
            for l in stat.split(separator: "\n") { let p = l.split(separator: "\t"); if p.count >= 3 { adds += Int(p[0]) ?? 0; dels += Int(p[1]) ?? 0; files += 1 } }
            var dirty = 0
            if let wt = wtByBranch[b.name], let st = try? await GitRepository(url: URL(fileURLWithPath: wt)).status() { dirty = st.changes.count }
            items.append(.init(agent: agent, branch: b.name, worktree: wtByBranch[b.name], commits: commits, filesChanged: files,
                               additions: adds, deletions: dels, lastActivity: b.lastCommit, dirtyFiles: dirty))
        }
        return items.sorted { ($0.isLive ? 1 : 0, $0.lastActivity) > ($1.isLive ? 1 : 0, $1.lastActivity) }
    }

    static func defaultBase(_ repo: GitRepository) async -> String {
        if let s = try? await Shell.check("git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: repo.url) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for c in ["main", "master", "develop"] {
            if (try? await Shell.check("git", ["rev-parse", "--verify", c], cwd: repo.url)) != nil { return c }
        }
        return "HEAD"
    }
}
