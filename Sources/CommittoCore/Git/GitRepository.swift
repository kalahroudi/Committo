import Foundation

/// Thin async wrapper over the `git` CLI. Using the CLI keeps behaviour identical to what users
/// (and agents) run in the terminal: hooks, signing, LFS, credential helpers all just work.
public struct GitRepository: Identifiable, Hashable, Codable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public var name: String { url.lastPathComponent }
    public init(url: URL) { self.url = url }

    /// Streams `git` output split on `separator` (see `Shell.records`); ending iteration early kills git.
    func gitRecords(_ args: [String], separator: UInt8) -> AsyncThrowingStream<Data, Error> {
        Shell.records("git", ["-c", "core.quotepath=off"] + args, cwd: url, separator: separator)
    }

    @discardableResult
    func git(_ args: [String], stdin: String? = nil) async throws -> String {
        try await Shell.check("git", ["-c", "core.quotepath=off"] + args, cwd: url, stdin: stdin)
    }

    public static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    public static func clone(_ remote: String, into dest: URL) -> AsyncThrowingStream<String, Error> {
        Shell.stream("git", ["clone", "--progress", remote, dest.path])
    }
    public static func initialize(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await Shell.check("git", ["init", "-b", "main"], cwd: url)
    }

    // MARK: Reading
    public func status() async throws -> RepoStatus {
        var parser = StatusParser()
        for try await entry in gitRecords(["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"], separator: 0) {
            parser.feed(String(decoding: entry, as: UTF8.self))
        }
        parser.finishPending()
        return parser.result
    }

    public func log(limit: Int = 500, all: Bool = true, path: String? = nil, ref: String? = nil, search: String? = nil, author: String? = nil) async throws -> [Commit] {
        var a = ["log", "--topo-order", "-n", "\(limit)", "--format=" + GitParse.logFormat, "--decorate=short"]
        if all && ref == nil { a.append("--all") }
        if let ref { a.append(ref) }
        if let search { a += ["-i", "--grep=" + search] }
        if let author { a.append("--author=" + author) }
        if let path { a += ["--follow", "--", path] }
        var out: [Commit] = []
        do {
            for try await rec in gitRecords(a, separator: 0x1E) {
                if let c = GitParse.commit(record: String(decoding: rec, as: UTF8.self)) { out.append(c) }
                if out.count >= limit { break }       // stops git; nothing past the page is read or buffered
            }
        } catch let e as ShellError where e.result.stderr.contains("does not have any commits") { return [] }
        return out
    }

    public func branches() async throws -> [Branch] {
        let fmt = "%(HEAD)%1f%(refname)%1f%(refname:short)%1f%(upstream:short)%1f%(committerdate:unix)%1f%(subject)%1f%(upstream:track,nobracket)"
        let out = try await git(["for-each-ref", "--format=" + fmt, "refs/heads", "refs/remotes"])
        return out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: GitParse.us)
            guard f.count >= 7, !f[1].hasSuffix("/HEAD") else { return nil }
            var ahead = 0, behind = 0
            for part in f[6].split(separator: ",") {
                let t = part.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("ahead ") { ahead = Int(t.dropFirst(6)) ?? 0 }
                if t.hasPrefix("behind ") { behind = Int(t.dropFirst(7)) ?? 0 }
            }
            return Branch(name: f[2], fullName: f[1], isRemote: f[1].hasPrefix("refs/remotes"), isCurrent: f[0] == "*",
                          upstream: f[3].isEmpty ? nil : f[3], lastCommit: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                          subject: f[5], ahead: ahead, behind: behind)
        }
    }

    public func currentBranch() async throws -> String { try await git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines) }
    public func headDate() async -> Date? {
        guard let s = try? await git(["log", "-1", "--format=%ct"]), let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    public func remoteURL(_ name: String = "origin") async -> String? { (try? await git(["remote", "get-url", name]))?.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func diff(path: String? = nil, staged: Bool = false, base: String? = nil, head: String? = nil, context: Int = 3) async throws -> [FileDiff] {
        var a = ["diff", "--no-color", "--no-ext-diff", "-U\(context)"]
        if staged { a.append("--cached") }
        if let base, let head { a.append("\(base)...\(head)") } else if let base { a.append(base) }
        if let path { a += ["--", path] }
        return try await parseDiff(a)
    }

    /// Streams a diff through `DiffParser`. Per-file line cap and a total byte cap keep huge diffs from exhausting memory.
    func parseDiff(_ args: [String], maxBytes: Int = 32 << 20) async throws -> [FileDiff] {
        var parser = DiffParser()
        var total = 0
        for try await line in gitRecords(args, separator: 0x0A) {
            total += line.count + 1
            if total > maxBytes { break }
            parser.feed(String(decoding: line, as: UTF8.self))
        }
        var files = parser.finish()
        if total > maxBytes, let last = files.popLast() {
            files.append(FileDiff(path: last.path, hunks: last.hunks, isBinary: last.isBinary, header: last.header, isTruncated: true))
        }
        return files
    }
    public func rawDiff(base: String, head: String) async throws -> String { try await git(["diff", "--no-color", "\(base)...\(head)"]) }
    public func show(_ hash: String) async throws -> [FileDiff] { try await parseDiff(["show", "--no-color", "--format=", hash]) }
    public func untrackedContent(_ path: String, maxBytes: Int = 1 << 20) -> FileDiff? {
        guard let h = try? FileHandle(forReadingFrom: url.appendingPathComponent(path)) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: maxBytes + 1) else { return nil }
        let cut = data.count > maxBytes
        let s = String(decoding: cut ? data.prefix(maxBytes) : data, as: UTF8.self)
        let lines = s.components(separatedBy: "\n")
        let dl = lines.enumerated().map { DiffLine(id: $0.offset, kind: .added, text: $0.element, oldLine: nil, newLine: $0.offset + 1) }
        return FileDiff(path: path, hunks: [DiffHunk(id: 0, header: "@@ new file @@", lines: dl, patch: "")], isBinary: false, header: "", isTruncated: cut)
    }

    public func stashes() async throws -> [Stash] {
        try await git(["stash", "list", "--format=%gd%x1f%gs"]).split(separator: "\n").compactMap {
            let f = $0.components(separatedBy: GitParse.us); return f.count == 2 ? Stash(ref: f[0], message: f[1]) : nil }
    }
    public func tags() async throws -> [Tag] {
        try await git(["for-each-ref", "--sort=-creatordate", "--format=%(refname:short)%1f%(objectname:short)%1f%(creatordate:unix)", "refs/tags"]).split(separator: "\n").compactMap {
            let f = $0.components(separatedBy: GitParse.us); return f.count == 3 ? Tag(name: f[0], hash: f[1], date: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0)) : nil }
    }
    public func worktrees() async throws -> [Worktree] {
        let out = try await git(["worktree", "list", "--porcelain"])
        var result: [Worktree] = []
        for block in out.components(separatedBy: "\n\n") where !block.isEmpty {
            var path = "", head = "", branch: String?
            for l in block.split(separator: "\n") {
                if l.hasPrefix("worktree ") { path = String(l.dropFirst(9)) }
                else if l.hasPrefix("HEAD ") { head = String(l.dropFirst(5)) }
                else if l.hasPrefix("branch ") { branch = String(l.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            }
            result.append(Worktree(path: path, head: head, branch: branch, isMain: result.isEmpty))
        }
        return result
    }
    public func reflog(limit: Int = 100) async throws -> [ReflogEntry] {
        try await git(["reflog", "-n", "\(limit)", "--format=%gd%x1f%H%x1f%gs%x1f%ct"]).split(separator: "\n").compactMap {
            let f = $0.components(separatedBy: GitParse.us)
            return f.count == 4 ? ReflogEntry(selector: f[0], hash: f[1], message: f[2], date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0)) : nil }
    }
    public func blame(_ path: String) async throws -> [BlameLine] {
        let out = try await git(["blame", "--line-porcelain", "--", path])
        var lines: [BlameLine] = [], hash = "", author = "", n = 0
        for l in out.components(separatedBy: "\n") {
            if l.hasPrefix("\t") { n += 1; lines.append(.init(line: n, hash: String(hash.prefix(7)), author: author, text: String(l.dropFirst()))) }
            else if l.hasPrefix("author ") { author = String(l.dropFirst(7)) }
            else if l.count >= 40, let first = l.split(separator: " ").first, first.count == 40, first.allSatisfy(\.isHexDigit) { hash = String(first) }
        }
        return lines
    }
    public func conflictedFiles() async throws -> [String] { try await git(["diff", "--name-only", "--diff-filter=U"]).split(separator: "\n").map(String.init) }
    public func fileContent(_ path: String, at rev: String = "HEAD") async throws -> String { try await git(["show", "\(rev):\(path)"]) }

    // MARK: Writing
    public func stage(_ paths: [String]) async throws { try await git(["add", "--"] + paths) }
    public func stageAll() async throws { try await git(["add", "-A"]) }
    public func unstage(_ paths: [String]) async throws { try await git(["restore", "--staged", "--"] + paths) }
    public func discard(_ paths: [String], untracked: Bool = false) async throws {
        if untracked { try await git(["clean", "-f", "--"] + paths) } else { try await git(["restore", "--"] + paths) }
    }
    /// Applies a patch to the index (or the work tree), or reverse-applies it to unstage or discard.
    /// Context lines are verified, so a patch never lands in the wrong place; `zeroContext` is only for `-U0` diffs.
    public func applyPatch(_ patch: String, reverse: Bool = false, toWorkTree: Bool = false, zeroContext: Bool = false) async throws {
        var a = ["apply", "--recount"]
        if zeroContext { a.append("--unidiff-zero") }
        if !toWorkTree { a.append("--cached") }
        if reverse { a.append("-R") }
        try await git(a, stdin: patch)
    }

    /// Stages only the chosen added/removed lines of one hunk of an unstaged diff.
    public func stageLines(_ file: FileDiff, hunk: DiffHunk, lines: Set<Int>) async throws {
        try await applyPatch(try PatchBuilder.patch(file: file, hunk: hunk, selected: lines, reverse: false))
    }
    /// Unstages only the chosen lines of one hunk of a staged (`--cached`) diff.
    public func unstageLines(_ file: FileDiff, hunk: DiffHunk, lines: Set<Int>) async throws {
        try await applyPatch(try PatchBuilder.patch(file: file, hunk: hunk, selected: lines, reverse: true), reverse: true)
    }
    /// Throws away only the chosen lines of one hunk of an unstaged diff (destructive: the work tree changes).
    public func discardLines(_ file: FileDiff, hunk: DiffHunk, lines: Set<Int>) async throws {
        try await applyPatch(try PatchBuilder.patch(file: file, hunk: hunk, selected: lines, reverse: true), reverse: true, toWorkTree: true)
    }
    public func commit(_ message: String, amend: Bool = false, signoff: Bool = false) async throws {
        var a = ["commit", "-m", message]
        if amend { a.append("--amend") }
        if signoff { a.append("-s") }
        try await git(a)
    }
    public func checkout(_ ref: String) async throws { try await git(["switch", ref]) }
    public func createBranch(_ name: String, from: String? = nil, checkout: Bool = true) async throws {
        if checkout { try await git(["switch", "-c", name] + (from.map { [$0] } ?? [])) } else { try await git(["branch", name] + (from.map { [$0] } ?? [])) }
    }
    public func deleteBranch(_ name: String, force: Bool = false) async throws { try await git(["branch", force ? "-D" : "-d", name]) }
    public func fetch(prune: Bool = true) async throws { try await git(["fetch", "--all"] + (prune ? ["--prune"] : [])) }
    public func pull(rebase: Bool = false) async throws { try await git(["pull"] + (rebase ? ["--rebase", "--autostash"] : ["--ff-only"])) }
    public func push(forceWithLease: Bool = false, setUpstream: Bool = false) async throws {
        var a = ["push"]
        if forceWithLease { a.append("--force-with-lease") }
        if setUpstream { a += ["-u", "origin", "HEAD"] }
        try await git(a)
    }
    public func merge(_ ref: String) async throws { try await git(["merge", "--no-edit", ref]) }
    public func rebase(onto ref: String) async throws { try await git(["rebase", "--autostash", ref]) }
    public func cherryPick(_ hash: String) async throws { try await git(["cherry-pick", hash]) }
    public func revert(_ hash: String) async throws { try await git(["revert", "--no-edit", hash]) }
    public func reset(_ ref: String, hard: Bool = false) async throws { try await git(["reset", hard ? "--hard" : "--mixed", ref]) }
    public func stashPush(message: String? = nil, includeUntracked: Bool = true) async throws {
        try await git(["stash", "push"] + (includeUntracked ? ["-u"] : []) + (message.map { ["-m", $0] } ?? []))
    }
    public func stashPop(_ ref: String = "stash@{0}") async throws { try await git(["stash", "pop", ref]) }
    public func stashApply(_ ref: String) async throws { try await git(["stash", "apply", ref]) }
    public func stashDrop(_ ref: String) async throws { try await git(["stash", "drop", ref]) }
    public func tag(_ name: String, at ref: String = "HEAD", message: String? = nil) async throws {
        try await git(message.map { ["tag", "-a", name, "-m", $0, ref] } ?? ["tag", name, ref])
    }
    public func addWorktree(path: String, branch: String, createBranch: Bool = true) async throws {
        try await git(createBranch ? ["worktree", "add", "-b", branch, path] : ["worktree", "add", path, branch])
    }
    public func removeWorktree(_ path: String) async throws { try await git(["worktree", "remove", "--force", path]) }
    public func updateSubmodules() async throws { try await git(["submodule", "update", "--init", "--recursive"]) }
    public func exportPatch(_ hash: String) async throws -> String { try await git(["format-patch", "-1", "--stdout", hash]) }
    public func abortOperation() async throws {
        for op in ["merge", "rebase", "cherry-pick", "revert"] { if (try? await git([op, "--abort"])) != nil { return } }
    }
    /// Undo the last history-changing action by resetting to the previous reflog entry (⌘Z).
    public func undoLast() async throws { try await git(["reset", "--keep", "HEAD@{1}"]) }
    public func gitignoreAdd(_ pattern: String) throws {
        let f = url.appendingPathComponent(".gitignore")
        let cur = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        try (cur + (cur.hasSuffix("\n") || cur.isEmpty ? "" : "\n") + pattern + "\n").write(to: f, atomically: true, encoding: .utf8)
    }

    // MARK: Insights
    public func commitCountsByDay(days: Int = 365) async throws -> [Date: Int] {
        let out = try await git(["log", "--all", "--since=\(days).days.ago", "--format=%ad", "--date=short"])
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        var r: [Date: Int] = [:]
        for l in out.split(separator: "\n") { if let d = f.date(from: String(l)) { r[d, default: 0] += 1 } }
        return r
    }
    public func contributors() async throws -> [(name: String, commits: Int)] {
        try await git(["shortlog", "-sn", "--all", "--no-merges", "HEAD"]).split(separator: "\n").compactMap {
            let p = $0.trimmingCharacters(in: .whitespaces).split(separator: "\t", maxSplits: 1)
            return p.count == 2 ? (String(p[1]), Int(p[0]) ?? 0) : nil }
    }
    /// Files changed most often: churn hotspots.
    public func hotspots(limit: Int = 15, days: Int = 180) async throws -> [(path: String, changes: Int)] {
        var c: [String: Int] = [:]
        for l in try await git(["log", "--since=\(days).days.ago", "--name-only", "--format="]).split(separator: "\n") { c[String(l), default: 0] += 1 }
        return c.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }
}
