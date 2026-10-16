import Foundation

public enum ForkError: LocalizedError, Equatable, Sendable {
    case timedOut(String)
    case upstreamConflict(existing: String)
    case noDefaultBranch
    case notFastForward(ahead: Int, behind: Int)
    case dirtyWorkingTree
    case defaultBranchNotCheckedOut(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let r): "\(r) was not ready in time. The provider is still creating the fork; try again in a moment."
        case .upstreamConflict(let u): "A remote named upstream already points to \(u). Remove or rename it first."
        case .noDefaultBranch: "Couldn't work out upstream's default branch."
        case .notFastForward(let a, let b): "Your default branch has \(a) commit\(a == 1 ? "" : "s") that upstream doesn't have (upstream has \(b) new). Choose rebase, merge or reset."
        case .dirtyWorkingTree: "You have uncommitted changes. Commit or stash them first; this would discard them."
        case .defaultBranchNotCheckedOut(let b): "Switch to \(b) first; rebase, merge and reset only run on the checked-out branch."
        }
    }
}

public enum ForkSyncStrategy: Sendable, Equatable { case fastForward, rebase, merge, resetToUpstream }

public struct ForkSyncPreview: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case upToDate, fastForward, localAhead, diverged }
    public let branch: String, upstreamRef: String
    public let ahead: Int, behind: Int
    public let localHead: String, upstreamHead: String
    public var kind: Kind {
        switch (ahead, behind) { case (0, 0): .upToDate; case (0, _): .fastForward; case (_, 0): .localAhead; default: .diverged }
    }
}

public struct ForkSyncResult: Sendable, Equatable {
    public let before: String, after: String
    public let pushed: Bool
    /// `refs/committo/backup/...` holding the old tip when the sync rewrote or moved history; nil for a plain fast-forward.
    public let backupRef: String?
}

public enum Fork {
    /// Polls `isReady` until it returns true. The provider creates forks asynchronously.
    public static func waitUntilReady(_ what: String, timeout: TimeInterval = 120, interval: TimeInterval = 2,
                                      isReady: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if try await isReady() { return }
            if Date() >= deadline { throw ForkError.timedOut(what) }
            try await Task.sleep(nanoseconds: UInt64(max(interval, 0.001) * 1_000_000_000))
        }
    }

    /// Forks on the provider, waits until the fork exists, and returns it.
    public static func create(on provider: HostingProvider, source: String, options: ForkOptions = ForkOptions(),
                              timeout: TimeInterval = 120, interval: TimeInterval = 2) async throws -> RemoteRepo {
        let fork = try await provider.fork(repo: source, options: options)
        try await waitUntilReady(fork.fullName, timeout: timeout, interval: interval) { try await provider.isForkReady(fullName: fork.fullName) }
        return fork
    }
}

extension GitRepository {
    static let backupPrefix = "refs/committo/backup/"

    /// Adds `upstream`, fetches it, and makes the default branch pull from upstream while still pushing to origin.
    /// Idempotent; refuses to repoint an existing `upstream` at a different URL.
    @discardableResult
    public func configureFork(upstreamURL: String, remote: String = "upstream") async throws -> String {
        if let existing = await remoteURL(remote) {
            guard existing == upstreamURL else { throw ForkError.upstreamConflict(existing: existing) }
        } else {
            try await git(["remote", "add", remote, upstreamURL])
        }
        try await git(["fetch", remote])
        let branch = try await upstreamDefaultBranch(remote: remote)
        if (try? await git(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"])) != nil {
            try await git(["config", "branch.\(branch).remote", remote])
            try await git(["config", "branch.\(branch).merge", "refs/heads/\(branch)"])
            try await git(["config", "branch.\(branch).pushRemote", "origin"])
        }
        return branch
    }

    public func upstreamDefaultBranch(remote: String = "upstream") async throws -> String {
        if (try? await git(["symbolic-ref", "-q", "refs/remotes/\(remote)/HEAD"])) == nil {
            _ = try? await git(["remote", "set-head", remote, "-a"])
        }
        guard let ref = (try? await git(["symbolic-ref", "-q", "--short", "refs/remotes/\(remote)/HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines),
              ref.hasPrefix(remote + "/") else { throw ForkError.noDefaultBranch }
        return String(ref.dropFirst(remote.count + 1))
    }

    /// Fetches upstream and compares its default branch with the local one. Changes nothing but remote-tracking refs.
    public func forkSyncPreview(remote: String = "upstream") async throws -> ForkSyncPreview {
        try await git(["fetch", remote])
        let branch = try await upstreamDefaultBranch(remote: remote)
        let up = "refs/remotes/\(remote)/\(branch)"
        let counts = try await git(["rev-list", "--left-right", "--count", "refs/heads/\(branch)...\(up)"]).split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard counts.count == 2, let ahead = Int(counts[0]), let behind = Int(counts[1]) else { throw ForkError.noDefaultBranch }
        let local = try await git(["rev-parse", "refs/heads/\(branch)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let head = try await git(["rev-parse", up]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ForkSyncPreview(branch: branch, upstreamRef: "\(remote)/\(branch)", ahead: ahead, behind: behind, localHead: local, upstreamHead: head)
    }

    /// Brings the default branch level with upstream and (optionally) pushes it to origin.
    /// Anything that rewrites or moves history records the old tip in `refs/committo/backup/` first and pushes only with a lease.
    /// `expectedOrigin` is the origin SHA the lease protects; by default it is read after fetching origin.
    public func syncFork(strategy: ForkSyncStrategy = .fastForward, push: Bool = true, remote: String = "upstream",
                         expectedOrigin: String? = nil) async throws -> ForkSyncResult {
        let p = try await forkSyncPreview(remote: remote)
        let branch = p.branch, up = "refs/remotes/\(remote)/\(branch)"
        let current = try? await git(["symbolic-ref", "-q", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let onBranch = current == branch
        var backup: String?
        var rewrote = false

        func snapshot() async throws {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let ref = "\(Self.backupPrefix)\(stamp)-\(branch)"
            try await git(["update-ref", ref, p.localHead])
            backup = ref
        }
        func requireClean() async throws {
            if !(try await git(["status", "--porcelain", "--untracked-files=no"])).isEmpty { throw ForkError.dirtyWorkingTree }
        }

        switch strategy {
        case .fastForward:
            if p.ahead > 0 && p.behind > 0 { throw ForkError.notFastForward(ahead: p.ahead, behind: p.behind) }
            if p.behind > 0 {
                if onBranch { try await git(["merge", "--ff-only", up]) }
                else { try await git(["fetch", ".", "\(up):refs/heads/\(branch)"]) }
            }
        case .rebase:
            guard onBranch else { throw ForkError.defaultBranchNotCheckedOut(branch) }
            if p.behind > 0 { try await requireClean(); try await snapshot(); try await git(["rebase", up]); rewrote = p.ahead > 0 }
        case .merge:
            guard onBranch else { throw ForkError.defaultBranchNotCheckedOut(branch) }
            if p.behind > 0 { try await requireClean(); try await snapshot(); try await git(["merge", "--no-edit", up]) }
        case .resetToUpstream:
            if p.localHead != p.upstreamHead {
                if onBranch { try await requireClean() }
                try await snapshot()
                if onBranch { try await git(["reset", "--hard", up]) } else { try await git(["branch", "-f", branch, up]) }
                rewrote = p.ahead > 0
            }
        }

        let after = try await git(["rev-parse", "refs/heads/\(branch)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var pushed = false
        if push {
            // Read origin's tip now so the lease is a real compare-and-swap.
            _ = try? await git(["fetch", "origin", branch])
            let originTip = (try? await git(["rev-parse", "--verify", "-q", "refs/remotes/origin/\(branch)"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let refspec = "refs/heads/\(branch):refs/heads/\(branch)"
            let originBehind = await isAncestor(originTip ?? "", of: after)
            if originTip == after {
                // already level
            } else if originBehind {
                try await git(["push", "origin", refspec]); pushed = true
            } else if rewrote || strategy == .resetToUpstream {
                // Origin has commits we are deliberately dropping: only with a lease on the SHA we saw.
                try await git(["push", "--force-with-lease=\(branch):\(expectedOrigin ?? originTip ?? "")", "origin", refspec]); pushed = true
            } else {
                try await git(["push", "origin", refspec]); pushed = true   // git refuses a non-fast-forward with its own message
            }
        }
        return ForkSyncResult(before: p.localHead, after: after, pushed: pushed, backupRef: backup)
    }

    func isAncestor(_ a: String, of b: String) async -> Bool {
        guard !a.isEmpty else { return true }
        return (try? await Shell.run("git", ["merge-base", "--is-ancestor", a, b], cwd: url))?.status == 0
    }

    /// Backup refs written by risky operations, newest first.
    public func backupRefs() async throws -> [String] {
        try await git(["for-each-ref", "--sort=-refname", "--format=%(refname)", Self.backupPrefix]).split(separator: "\n").map(String.init)
    }
}
