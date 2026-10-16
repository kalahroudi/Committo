import Foundation

public struct Commit: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let parents: [String]
    public let author: String
    public let email: String
    public let date: Date
    public let refs: [String]
    public let subject: String
    public let coAuthors: [String]
    public var shortHash: String { String(hash.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

public enum ChangeKind: String, Sendable { case added = "A", modified = "M", deleted = "D", renamed = "R", copied = "C", untracked = "?", conflicted = "U", unknown = " " }

public struct FileChange: Identifiable, Hashable, Sendable {
    public var id: String { path + (staged ? "#s" : "#w") }
    public let path: String
    public let oldPath: String?
    public let kind: ChangeKind
    public let staged: Bool
}

public struct RepoStatus: Sendable {
    public var branch: String = "HEAD"
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var changes: [FileChange] = []
    public var staged: [FileChange] { changes.filter(\.staged) }
    public var unstaged: [FileChange] { changes.filter { !$0.staged } }
    public var isClean: Bool { changes.isEmpty }
    public init() {}
}

public struct Branch: Identifiable, Hashable, Sendable {
    public var id: String { fullName }
    public let name: String
    public let fullName: String
    public let isRemote: Bool
    public let isCurrent: Bool
    public let upstream: String?
    public let lastCommit: Date
    public let subject: String
    public let ahead: Int
    public let behind: Int
}

public struct Stash: Identifiable, Hashable, Sendable { public var id: String { ref }; public let ref: String; public let message: String }
public struct Tag: Identifiable, Hashable, Sendable { public var id: String { name }; public let name: String; public let hash: String; public let date: Date }
public struct Worktree: Identifiable, Hashable, Sendable { public var id: String { path }; public let path: String; public let head: String; public let branch: String?; public let isMain: Bool }
public struct ReflogEntry: Identifiable, Hashable, Sendable { public var id: String { selector }; public let selector: String; public let hash: String; public let message: String; public let date: Date }
public struct BlameLine: Identifiable, Sendable { public var id: Int { line }; public let line: Int; public let hash: String; public let author: String; public let text: String }

public struct DiffLine: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case context, added, removed, header }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
    /// Followed by git's `\ No newline at end of file` marker.
    public var noNewlineAtEnd = false
}
public struct DiffHunk: Identifiable, Hashable, Sendable { public var id: Int; public let header: String; public let lines: [DiffLine]; public let patch: String }
public struct FileDiff: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let hunks: [DiffHunk]
    public let isBinary: Bool
    public let header: String
    /// True when the file's diff was cut at the size limit; the hunks shown are a prefix.
    public var isTruncated = false
    public var additions: Int { hunks.flatMap(\.lines).filter { $0.kind == .added }.count }
    public var deletions: Int { hunks.flatMap(\.lines).filter { $0.kind == .removed }.count }
}

extension FileDiff {
    /// Diff lines kept per file before the rest is dropped and `isTruncated` is set.
    public static let maxLinesPerFile = DiffParser.defaultMaxLinesPerFile
}
