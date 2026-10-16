import Foundation

enum GitParse {
    static let us = "\u{1f}", rs = "\u{1e}"
    static let logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1f%(trailers:key=Co-Authored-By,valueonly,separator=%x2c)%x1e"

    static func commits(_ out: String) -> [Commit] { out.components(separatedBy: rs).compactMap { commit(record: $0) } }

    /// One `logFormat` record (without the trailing RS).
    static func commit(record rec: String) -> Commit? {
        let f = rec.trimmingCharacters(in: .newlines).components(separatedBy: us)
        guard f.count >= 7, f[0].count >= 40 else { return nil }
        let co = f.count > 7 ? f[7].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } : []
        return Commit(hash: f[0], parents: f[1].split(separator: " ").map(String.init), author: f[2], email: f[3],
                      date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                      refs: f[5].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                      subject: f[6], coAuthors: co)
    }

    /// `git status --porcelain=v1 -z --branch`
    static func status(_ out: String) -> RepoStatus {
        var p = StatusParser()
        for e in out.components(separatedBy: "\0") { p.feed(e) }
        p.finishPending()
        return p.result
    }

    static func diff(_ text: String, maxLinesPerFile: Int = DiffParser.defaultMaxLinesPerFile) -> [FileDiff] {
        var p = DiffParser(maxLinesPerFile: maxLinesPerFile)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) { p.feed(String(line)) }
        return p.finish()
    }
}

/// Incremental parser for `git status --porcelain=v1 -z --branch`: feed NUL-separated entries one at a time.
struct StatusParser {
    private(set) var result = RepoStatus()
    private var first = true
    private var renameOf: (x: Character, y: Character, path: String)?

    mutating func feed(_ e: String) {
        if let r = renameOf {          // the entry after a rename/copy is the original path
            renameOf = nil
            emit(x: r.x, y: r.y, path: r.path, old: e)
            return
        }
        defer { first = false }
        if first, e.hasPrefix("## ") { header(String(e.dropFirst(3))); return }
        guard e.count > 3 else { return }
        let x = e[e.startIndex], y = e[e.index(after: e.startIndex)]
        let path = String(e.dropFirst(3))
        if x == "R" || x == "C" || y == "R" || y == "C" { renameOf = (x, y, path); return }
        emit(x: x, y: y, path: path, old: nil)
    }

    /// Call after the last entry; a dangling rename (truncated output) is emitted without its old path.
    mutating func finishPending() {
        if let r = renameOf { renameOf = nil; emit(x: r.x, y: r.y, path: r.path, old: nil) }
    }

    private mutating func header(_ h: String) {
        var line = h
        if let r = line.range(of: " [") {
            let meta = line[r.upperBound...].dropLast()
            for item in meta.split(separator: ",") {
                let t = item.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("ahead ") { result.ahead = Int(t.dropFirst(6)) ?? 0 }
                if t.hasPrefix("behind ") { result.behind = Int(t.dropFirst(7)) ?? 0 }
            }
            line = String(line[..<r.lowerBound])
        }
        if let r = line.range(of: "...") { result.branch = String(line[..<r.lowerBound]); result.upstream = String(line[r.upperBound...]) }
        else { result.branch = line.replacingOccurrences(of: "No commits yet on ", with: "") }
    }

    private mutating func emit(x: Character, y: Character, path: String, old: String?) {
        if x == "?" && y == "?" { result.changes.append(.init(path: path, oldPath: nil, kind: .untracked, staged: false)); return }
        let conflict = x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D")
        if conflict { result.changes.append(.init(path: path, oldPath: nil, kind: .conflicted, staged: false)); return }
        if x != " " { result.changes.append(.init(path: path, oldPath: old, kind: ChangeKind(rawValue: String(x)) ?? .unknown, staged: true)) }
        if y != " " { result.changes.append(.init(path: path, oldPath: old, kind: ChangeKind(rawValue: String(y)) ?? .unknown, staged: false)) }
    }
}

/// Incremental unified-diff parser: feed one line at a time, memory is bounded by the cap per file.
/// Hunk lines beyond `maxLinesPerFile` are dropped and the file is flagged `isTruncated`.
struct DiffParser {
    static let defaultMaxLinesPerFile = 20_000
    let maxLinesPerFile: Int
    private(set) var files: [FileDiff] = []

    private var head: String?
    private var path = ""
    private var binary = false
    private var headerLines: [String] = []
    private var hunks: [DiffHunk] = []
    private var cur: (h: String, ls: [DiffLine], raw: [String])?
    private var oldN = 0, newN = 0, lid = 0, lineCount = 0
    private var truncated = false

    init(maxLinesPerFile: Int = DiffParser.defaultMaxLinesPerFile) { self.maxLinesPerFile = maxLinesPerFile }

    mutating func feed(_ l: String) {
        if l.hasPrefix("diff --git ") { closeFile(); head = String(l.dropFirst(11)); path = head!.components(separatedBy: " b/").last ?? head!; return }
        guard head != nil else { return }
        if l.hasPrefix("@@") {
            closeHunk()
            let nums = l.split(separator: " ").dropFirst().prefix(2).map { $0.dropFirst().split(separator: ",").first ?? "0" }
            oldN = Int(nums.first ?? "0") ?? 0; newN = Int(nums.last ?? "0") ?? 0
            cur = (l, [], [l])
            return
        }
        guard cur != nil else {
            if l.hasPrefix("+++ b/") { path = String(l.dropFirst(6)) }
            if l.hasPrefix("Binary files") || l.hasPrefix("GIT binary patch") { binary = true }
            headerLines.append(l)
            return
        }
        guard let c = l.first else { return }
        if c == "\\" {            // "\ No newline at end of file" belongs to the line before it
            if !cur!.ls.isEmpty, !truncated { cur!.ls[cur!.ls.count - 1].noNewlineAtEnd = true; cur!.raw.append(l) }
            return
        }
        if lineCount >= maxLinesPerFile { truncated = true; return }
        lineCount += 1; lid += 1
        switch c {
        case "+": cur!.ls.append(.init(id: lid, kind: .added, text: String(l.dropFirst()), oldLine: nil, newLine: newN)); newN += 1
        case "-": cur!.ls.append(.init(id: lid, kind: .removed, text: String(l.dropFirst()), oldLine: oldN, newLine: nil)); oldN += 1
        default: cur!.ls.append(.init(id: lid, kind: .context, text: String(l.dropFirst()), oldLine: oldN, newLine: newN)); oldN += 1; newN += 1
        }
        cur!.raw.append(l)
    }

    mutating func finish() -> [FileDiff] { closeFile(); return files }

    private mutating func closeHunk() {
        if let c = cur { hunks.append(.init(id: hunks.count, header: c.h, lines: c.ls, patch: c.raw.joined(separator: "\n") + "\n")) }
        cur = nil
    }
    private mutating func closeFile() {
        guard let head else { return }
        closeHunk()
        files.append(.init(path: path, hunks: hunks, isBinary: binary, header: "diff --git " + head + "\n" + headerLines.joined(separator: "\n"), isTruncated: truncated))
        self.head = nil; path = ""; binary = false; headerLines = []; hunks = []; cur = nil
        oldN = 0; newN = 0; lid = 0; lineCount = 0; truncated = false
    }
}
