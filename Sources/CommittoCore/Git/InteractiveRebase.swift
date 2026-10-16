import Foundation

public enum RebaseAction: String, Sendable, Equatable, CaseIterable { case pick, reword, edit, squash, fixup, drop }

public struct RebaseStep: Sendable, Equatable, Identifiable {
    public var id: String { hash }
    public let hash: String
    public var subject: String
    public var action: RebaseAction
    /// Replacement commit message for `reword`, or for the result of a `squash` / `fixup` group head's last step.
    public var message: String?
    public init(hash: String, subject: String = "", action: RebaseAction = .pick, message: String? = nil) {
        self.hash = hash; self.subject = subject; self.action = action; self.message = message
    }
}

public enum RebaseError: LocalizedError, Equatable, Sendable {
    case emptyPlan
    case planMismatch(missing: [String], unknown: [String], duplicated: [String])
    case firstStepCannotSquash
    case containsMerges(Int)
    case alreadyInProgress
    case notInProgress
    case messageNeeded(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPlan: "There are no commits to rebase."
        case .planMismatch(let m, let u, let d):
            "The plan doesn't match the branch. " + [m.isEmpty ? nil : "Missing: \(m.map { String($0.prefix(7)) }.joined(separator: ", ")) (mark a commit Drop to remove it)",
                                                      u.isEmpty ? nil : "Not on this branch: \(u.map { String($0.prefix(7)) }.joined(separator: ", "))",
                                                      d.isEmpty ? nil : "Listed twice: \(d.map { String($0.prefix(7)) }.joined(separator: ", "))"].compactMap { $0 }.joined(separator: ". ")
        case .firstStepCannotSquash: "The first commit can't be squashed or fixed up because there's nothing before it. Use Pick for it."
        case .containsMerges(let n): "This range contains \(n) merge commit\(n == 1 ? "" : "s"). Interactive rebase would flatten them, so it's not offered here."
        case .alreadyInProgress: "A rebase is already in progress. Continue, skip or abort it first."
        case .notInProgress: "There's no rebase in progress."
        case .messageNeeded(let h): "Reword needs a new message for \(h.prefix(7))."
        }
    }
}

public struct RebaseState: Sendable, Equatable {
    public var inProgress: Bool
    public var step: Int, total: Int
    public var conflictedFiles: [String]
    public static let idle = RebaseState(inProgress: false, step: 0, total: 0, conflictedFiles: [])
}

public enum RebaseOutcome: Sendable, Equatable {
    /// Finished. `needsForcePush` is true when rewritten commits were already on the upstream branch.
    case completed(head: String, backupRef: String?, needsForcePush: Bool, expectedRemote: String?)
    /// Stopped at an `edit` step or a conflict; continue, skip or abort.
    case stopped(RebaseState)
}

public struct RebasePreview: Sendable, Equatable {
    public let rewritten: [String]      // commits that get new hashes
    public let dropped: [String]        // commits that become unreachable from the branch
    public let unchanged: [String]      // leading commits left exactly as they are
}

public enum InteractiveRebase {
    /// Which commits change identity: everything from the first step that differs from the original order/action onward.
    public static func preview(original: [String], plan: [RebaseStep]) -> RebasePreview {
        var firstChange = plan.count
        for (i, s) in plan.enumerated() where i >= original.count || s.hash != original[i] || s.action != .pick || s.message != nil { firstChange = i; break }
        if plan.count < original.count { firstChange = min(firstChange, plan.count) }
        let dropped = plan.filter { $0.action == .drop }.map(\.hash)
        let kept = plan.dropFirst(firstChange).filter { $0.action != .drop }.map(\.hash)
        return RebasePreview(rewritten: kept, dropped: dropped, unchanged: Array(plan.prefix(firstChange)).map(\.hash))
    }

    /// Moves `fixup! x` / `squash! x` commits directly after the commit whose subject (or hash prefix) is `x`, and sets their action.
    public static func autosquash(_ steps: [RebaseStep]) -> [RebaseStep] {
        func marker(_ subject: String) -> (prefix: String, action: RebaseAction)? {
            if subject.hasPrefix("fixup! ") { return ("fixup! ", .fixup) }
            if subject.hasPrefix("squash! ") { return ("squash! ", .squash) }
            return nil
        }
        var out = steps
        var i = 0
        while i < out.count {
            guard let m = marker(out[i].subject) else { i += 1; continue }
            let target = String(out[i].subject.dropFirst(m.prefix.count))
            let earlier = out[..<i]
            guard let t = earlier.lastIndex(where: { marker($0.subject) == nil && ($0.subject == target || $0.hash.hasPrefix(target)) })
                    ?? earlier.lastIndex(where: { marker($0.subject) == nil && $0.subject.hasPrefix(target) }) else { i += 1; continue }
            var moved = out.remove(at: i)
            moved.action = m.action
            var at = t + 1
            while at < i, out[at].action == .fixup || out[at].action == .squash { at += 1 }   // keep earlier fixups of the same target first
            out.insert(moved, at: at)
            i += 1
        }
        return out
    }

    static func todo(_ plan: [RebaseStep], messageFile: (RebaseStep) -> String?) -> String {
        var lines: [String] = []
        for s in plan {
            lines.append("\(s.action.rawValue == "reword" ? "pick" : s.action.rawValue) \(s.hash)")
            if s.action != .drop, let f = messageFile(s) {
                lines.append("exec git commit --amend -q --allow-empty -F \(shellQuote(f))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension GitRepository {
    /// Creates `refs/committo/backup/<stamp>-<label>-<sha7>` pointing at `sha`.
    @discardableResult
    func createBackup(label: String, sha: String) async throws -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let safe = label.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? String($0) : "-" }.joined()
        let ref = "\(Self.backupPrefix)\(stamp)-\(safe)-\(sha.prefix(7))"
        try await git(["update-ref", ref, sha])
        return ref
    }

    func gitPath(_ name: String) async throws -> URL {
        let p = try await git(["rev-parse", "--git-path", name]).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : url.appendingPathComponent(p)
    }

    /// Commits `base..HEAD`, oldest first, as `pick` steps. Throws when the range holds merges.
    public func rebasePlan(onto base: String) async throws -> [RebaseStep] {
        let merges = try await git(["rev-list", "--merges", "--count", "\(base)..HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(merges), n > 0 { throw RebaseError.containsMerges(n) }
        let out = try await git(["log", "--reverse", "--format=%H%x1f%s", "\(base)..HEAD"])
        let steps = out.split(separator: "\n").compactMap { l -> RebaseStep? in
            let f = l.components(separatedBy: "\u{1f}"); guard f.count >= 2 else { return nil }
            return RebaseStep(hash: f[0], subject: f[1])
        }
        guard !steps.isEmpty else { throw RebaseError.emptyPlan }
        return steps
    }

    public func rebaseState() async -> RebaseState {
        guard let dir = try? await gitPath("rebase-merge"), FileManager.default.fileExists(atPath: dir.path) else { return .idle }
        func int(_ f: String) -> Int { Int((try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
        let conflicts = ((try? await git(["diff", "--name-only", "--diff-filter=U"])) ?? "").split(separator: "\n").map(String.init)
        return RebaseState(inProgress: true, step: int("msgnum"), total: int("end"), conflictedFiles: conflicts)
    }

    /// Runs the plan. Validates first (nothing is touched on a bad plan), saves a backup ref, then rebases with autostash.
    public func interactiveRebase(onto base: String, plan: [RebaseStep]) async throws -> RebaseOutcome {
        guard await !rebaseState().inProgress else { throw RebaseError.alreadyInProgress }
        let original = try await rebasePlan(onto: base)
        try Self.validate(plan: plan, against: original.map(\.hash))

        let head = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (try? await git(["symbolic-ref", "-q", "--short", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "detached"
        let upstreamTip = (try? await git(["rev-parse", "--verify", "-q", "@{upstream}"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let backup = try await createBackup(label: "\(branch)-rebase", sha: head)

        let work = try await gitPath("committo-rebase")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var files: [String: String] = [:]
        for (i, s) in plan.enumerated() {
            if let m = s.message {
                let f = work.appendingPathComponent("msg-\(i).txt"); try m.write(to: f, atomically: true, encoding: .utf8); files[s.hash] = f.path
            }
        }
        let todoFile = work.appendingPathComponent("todo")
        try InteractiveRebase.todo(plan) { files[$0.hash] }.write(to: todoFile, atomically: true, encoding: .utf8)

        let meta = RebaseMeta(backupRef: backup, expectedRemote: upstreamTip, original: original.map(\.hash))
        try JSONEncoder().encode(meta).write(to: work.appendingPathComponent("meta.json"))

        let env = ["GIT_SEQUENCE_EDITOR": "cp \(InteractiveRebase.shellQuote(todoFile.path))", "GIT_EDITOR": "true"]
        let r = try await Shell.run("git", ["rebase", "-i", "--autostash", "--no-autosquash", "--no-rebase-merges", base], cwd: url, env: env)
        return try await finish(r)
    }

    public func continueRebase() async throws -> RebaseOutcome { try await advance("--continue") }
    public func skipRebase() async throws -> RebaseOutcome { try await advance("--skip") }
    /// Returns the branch to exactly where it was before the rebase started.
    public func abortRebase() async throws {
        guard await rebaseState().inProgress else { throw RebaseError.notInProgress }
        try await git(["rebase", "--abort"])
        try? FileManager.default.removeItem(at: try await gitPath("committo-rebase"))
    }

    /// Pushes a rewritten branch with a lease on the remote SHA seen before the rebase.
    public func pushRewritten(expectedRemote: String?, remote: String = "origin") async throws {
        let branch = try await git(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lease = expectedRemote.map { "--force-with-lease=\(branch):\($0)" } ?? "--force-with-lease"
        try await git(["push", lease, remote, "refs/heads/\(branch):refs/heads/\(branch)"])
    }

    // MARK: internals
    static func validate(plan: [RebaseStep], against original: [String]) throws {
        guard !plan.isEmpty else { throw RebaseError.emptyPlan }
        let listed = plan.map(\.hash)
        var seen = Set<String>(), dup: [String] = []
        for h in listed where !seen.insert(h).inserted { dup.append(h) }
        let missing = original.filter { !seen.contains($0) }, unknown = listed.filter { !original.contains($0) }
        if !missing.isEmpty || !unknown.isEmpty || !dup.isEmpty { throw RebaseError.planMismatch(missing: missing, unknown: unknown, duplicated: dup) }
        if let first = plan.first(where: { $0.action != .drop }), first.action == .squash || first.action == .fixup { throw RebaseError.firstStepCannotSquash }
        for s in plan where s.action == .reword && (s.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw RebaseError.messageNeeded(s.hash) }
    }

    private func advance(_ flag: String) async throws -> RebaseOutcome {
        guard await rebaseState().inProgress else { throw RebaseError.notInProgress }
        let r = try await Shell.run("git", ["rebase", flag], cwd: url, env: ["GIT_EDITOR": "true"])
        return try await finish(r)
    }

    private func finish(_ r: ShellResult) async throws -> RebaseOutcome {
        let state = await rebaseState()
        if state.inProgress { return .stopped(state) }
        let work = try await gitPath("committo-rebase")
        let meta = (try? Data(contentsOf: work.appendingPathComponent("meta.json"))).flatMap { try? JSONDecoder().decode(RebaseMeta.self, from: $0) }
        guard r.ok else { try? FileManager.default.removeItem(at: work); throw ShellError(command: "git rebase", result: r) }
        try? FileManager.default.removeItem(at: work)
        let head = try await git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var pushed = false
        if let tip = meta?.expectedRemote, !tip.isEmpty {
            // Rewritten commits were published if the remote branch contains any of the originals.
            for h in meta?.original ?? [] {
                let published = await isAncestor(h, of: tip)
                if published { pushed = true; break }
            }
        }
        return .completed(head: head, backupRef: meta?.backupRef, needsForcePush: pushed, expectedRemote: meta?.expectedRemote)
    }
}

struct RebaseMeta: Codable { let backupRef: String, expectedRemote: String?, original: [String] }
