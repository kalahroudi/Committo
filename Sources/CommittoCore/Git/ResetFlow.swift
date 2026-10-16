import Foundation

public enum ResetMode: String, Sendable, CaseIterable { case soft, mixed, hard, keep }

public struct CommitRef: Sendable, Equatable, Hashable { public let hash: String, subject: String }

public struct ResetPreview: Sendable, Equatable {
    public let target: String, mode: ResetMode
    /// Commits that stop being on the branch (they stay reachable from the backup ref).
    public let leaving: [CommitRef]
    /// Commits the branch gains (resetting forward).
    public let gaining: [CommitRef]
    /// Uncommitted tracked changes a hard reset throws away.
    public let changesLost: Int
    /// Of `leaving`, how many are already on the upstream branch (publishing the reset then needs a force push).
    public let publishedLeaving: Int
    /// Names the loss, e.g. "Reset hard, 4 changes lost".
    public var buttonTitle: String {
        switch mode {
        case .hard: changesLost > 0 ? "Reset hard, \(changesLost) change\(changesLost == 1 ? "" : "s") lost" : "Reset hard"
        case .soft: "Reset soft"
        case .mixed: "Reset mixed, unstage changes"
        case .keep: "Reset, keep local changes"
        }
    }
}

/// What a risky operation saved first. `restore` puts the branch, index and tracked changes back exactly.
public struct OperationSnapshot: Sendable, Equatable {
    public let headBackup: String
    public let worktreeBackup: String?
    public let branch: String?
}

public enum ResetFlowError: LocalizedError, Equatable, Sendable {
    case wrongBranch(expected: String?, actual: String?)
    case remoteMoved(String)
    case plainForceRefused(String)
    case noRemoteBranch(String)
    case nothingToPush
    case needsDecision

    public var errorDescription: String? {
        switch self {
        case .wrongBranch(let e, let a): "This snapshot belongs to \(e ?? "a detached HEAD") but you're on \(a ?? "a detached HEAD"). Switch back first."
        case .remoteMoved(let b): "The remote \(b) has commits you haven't fetched, so nothing was overwritten. Fetch and review them, then try again."
        case .plainForceRefused(let why): "Plain force push refused: \(why). Use force-with-lease."
        case .noRemoteBranch(let b): "\(b) doesn't exist on the remote yet; a normal push is enough."
        case .nothingToPush: "The remote already has exactly this commit."
        case .needsDecision: "You have uncommitted changes that conflict with the other branch. Choose carry over, stash or discard."
        }
    }
}

public struct BackupInfo: Sendable, Equatable {
    public let ref: String, label: String, date: Date, sha: String, subject: String
}

public enum SwitchPolicy: Sendable, Equatable { case carry, stash, discard }

public struct ForcePushPlan: Sendable, Equatable {
    public let remote: String, branch: String
    public let local: String
    /// The remote SHA you last saw. The lease protects exactly this value.
    public let expectedRemote: String?
    /// Commits on the remote that this push would delete from it.
    public let overwrites: [CommitRef]
    public let adds: Int
}

public enum ForcePushMode: Sendable, Equatable {
    case lease
    /// Advanced: refused unless `allowPlain` is set and the branch is not known to be protected.
    case plain(allowPlain: Bool, branchIsProtected: Bool)
}

extension GitRepository {
    // MARK: Reset
    public func resetPreview(to target: String, mode: ResetMode) async throws -> ResetPreview {
        let t = try await git(["rev-parse", "--verify", "\(target)^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let leaving = try await commits("\(t)..HEAD"), gaining = try await commits("HEAD..\(t)")
        var lost = 0
        if mode == .hard {
            lost = try await git(["status", "--porcelain", "--untracked-files=no"]).split(separator: "\n").count
        }
        var published = 0
        if let up = try? await git(["rev-parse", "--verify", "-q", "@{upstream}"]).trimmingCharacters(in: .whitespacesAndNewlines), !up.isEmpty {
            let pub = Set(try await commits("\(t)..\(up)").map(\.hash))
            published = leaving.filter { pub.contains($0.hash) }.count
        }
        return ResetPreview(target: t, mode: mode, leaving: leaving, gaining: gaining, changesLost: lost, publishedLeaving: published)
    }

    func commits(_ range: String, limit: Int = 10_000) async throws -> [CommitRef] {
        try await git(["log", "-n", "\(limit)", "--format=%H%x1f%s", range]).split(separator: "\n").compactMap {
            let f = $0.components(separatedBy: "\u{1f}"); return f.count >= 2 ? CommitRef(hash: f[0], subject: f[1]) : nil
        }
    }

    func currentBranchName() async -> String? {
        (try? await git(["symbolic-ref", "-q", "--short", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saves the current tip and (when there are tracked changes) the index and working tree as commits under `refs/committo/backup/`.
    func takeSnapshot(label: String) async throws -> OperationSnapshot {
        let head = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = await currentBranchName()
        let headRef = try await createBackup(label: label, sha: head)
        var wt: String?
        let stash = try await git(["stash", "create"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stash.isEmpty { wt = try await createBackup(label: "\(label)-worktree", sha: stash) }
        return OperationSnapshot(headBackup: headRef, worktreeBackup: wt, branch: branch)
    }

    func discardSnapshot(_ s: OperationSnapshot) async {
        _ = try? await git(["update-ref", "-d", s.headBackup])
        if let w = s.worktreeBackup { _ = try? await git(["update-ref", "-d", w]) }
    }

    /// Snapshot first, then reset. If git refuses (e.g. `--keep` with conflicting changes) nothing changes and no backup is left behind.
    @discardableResult
    public func resetSafely(to target: String, mode: ResetMode) async throws -> OperationSnapshot {
        let snap = try await takeSnapshot(label: "\(await currentBranchName() ?? "detached")-reset-\(mode.rawValue)")
        do { try await git(["reset", "--\(mode.rawValue)", target]) } catch { await discardSnapshot(snap); throw error }
        return snap
    }

    /// Puts the branch, index and tracked changes back as they were when `snapshot` was taken. The current state is itself backed up first.
    @discardableResult
    public func restore(_ snapshot: OperationSnapshot) async throws -> OperationSnapshot {
        let now = await currentBranchName()
        guard now == snapshot.branch else { throw ResetFlowError.wrongBranch(expected: snapshot.branch, actual: now) }
        let undoOfUndo = try await takeSnapshot(label: "\(now ?? "detached")-restore")
        let head = try await git(["rev-parse", snapshot.headBackup]).trimmingCharacters(in: .whitespacesAndNewlines)
        try await git(["reset", "--hard", head])
        if let w = snapshot.worktreeBackup {
            let sha = try await git(["rev-parse", w]).trimmingCharacters(in: .whitespacesAndNewlines)
            try await git(["stash", "apply", "--index", sha])
        }
        return undoOfUndo
    }

    // MARK: Backups
    static let backupStampFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"; return f
    }()

    public func listBackups() async throws -> [BackupInfo] {
        let out = try await git(["for-each-ref", "--sort=-refname", "--format=%(refname)%1f%(objectname)%1f%(contents:subject)", Self.backupPrefix])
        return out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\u{1f}"); guard f.count >= 3 else { return nil }
            let name = String(f[0].dropFirst(Self.backupPrefix.count))
            guard name.count > 19, let date = Self.backupStampFormat.date(from: String(name.prefix(18))) else { return nil }
            var label = String(name.dropFirst(19))
            if label.count > 8, label[label.index(label.endIndex, offsetBy: -8)] == "-" { label = String(label.dropLast(8)) }   // "-<sha7>"
            return BackupInfo(ref: f[0], label: label, date: date, sha: f[1], subject: f[2])
        }
    }

    /// Deletes backup refs older than `days` (default 30). Returns how many were removed.
    @discardableResult
    public func pruneBackups(olderThanDays days: Int = 30, now: Date = Date()) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var n = 0
        for b in try await listBackups() where b.date < cutoff { try await git(["update-ref", "-d", b.ref]); n += 1 }
        return n
    }

    // MARK: Force push
    /// What a force push would do, from what you last fetched. Does not fetch: the lease protects the SHA you actually reviewed.
    public func forcePushPlan(remote: String = "origin", branch: String? = nil) async throws -> ForcePushPlan {
        let b: String
        if let branch { b = branch } else if let cur = await currentBranchName() { b = cur } else { throw ResetFlowError.noRemoteBranch("HEAD") }
        let local = try await git(["rev-parse", "refs/heads/\(b)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tracking = "refs/remotes/\(remote)/\(b)"
        guard let expected = (try? await git(["rev-parse", "--verify", "-q", tracking]))?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty else {
            throw ResetFlowError.noRemoteBranch(b)
        }
        if expected == local { throw ResetFlowError.nothingToPush }
        let overwrites = try await commits("refs/heads/\(b)..\(tracking)"), adds = try await commits("\(tracking)..refs/heads/\(b)").count
        return ForcePushPlan(remote: remote, branch: b, local: local, expectedRemote: expected, overwrites: overwrites, adds: adds)
    }

    /// Force pushes. The remote's old tip is kept as a local backup ref first, so the overwritten commits stay recoverable.
    public func forcePush(_ plan: ForcePushPlan, mode: ForcePushMode = .lease) async throws {
        let refspec = "refs/heads/\(plan.branch):refs/heads/\(plan.branch)"
        var args: [String]
        switch mode {
        case .lease:
            guard let exp = plan.expectedRemote else { throw ResetFlowError.noRemoteBranch(plan.branch) }
            args = ["push", "--force-with-lease=\(plan.branch):\(exp)", plan.remote, refspec]
        case .plain(let allow, let isProtected):
            if isProtected { throw ResetFlowError.plainForceRefused("\(plan.branch) is protected") }
            if !allow { throw ResetFlowError.plainForceRefused("it was not explicitly enabled") }
            args = ["push", "--force", plan.remote, refspec]
        }
        if let exp = plan.expectedRemote { _ = try? await createBackup(label: "remote-\(plan.remote)-\(plan.branch)", sha: exp) }
        do { try await git(args) } catch let e as ShellError {
            if e.result.stderr.contains("stale info") || e.result.stderr.contains("rejected") && e.result.stderr.contains("fetch first") { throw ResetFlowError.remoteMoved(plan.branch) }
            throw e
        }
    }

    // MARK: Switching and detached HEAD
    public var isDetached: Bool { get async { await currentBranchName() == nil } }

    /// Switches branches with uncommitted changes handled as chosen. `stash` includes untracked files and names the stash.
    /// Returns the snapshot when changes could be lost (`discard`).
    @discardableResult
    public func switchBranch(_ name: String, policy: SwitchPolicy) async throws -> OperationSnapshot? {
        switch policy {
        case .carry:
            do { try await git(["switch", name]) } catch let e as ShellError where e.result.stderr.contains("would be overwritten") || e.result.stderr.contains("local changes") {
                throw ResetFlowError.needsDecision
            }
            return nil
        case .stash:
            let from = await currentBranchName() ?? "detached"
            if !(try await git(["status", "--porcelain"])).isEmpty { try await git(["stash", "push", "-u", "-m", "Committo: before switching from \(from) to \(name)"]) }
            try await git(["switch", name]); return nil
        case .discard:
            let snap = try await takeSnapshot(label: "\(await currentBranchName() ?? "detached")-switch")
            do { try await git(["switch", "--discard-changes", name]) } catch { await discardSnapshot(snap); throw error }
            return snap
        }
    }

    /// Detached HEAD → a real branch at the current commit.
    public func saveDetachedHead(as branch: String) async throws { try await git(["switch", "-c", branch]) }
}
