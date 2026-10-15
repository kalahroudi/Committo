import Foundation

enum GitParse {
    static let us = "\u{1f}", rs = "\u{1e}"
    static let logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1f%(trailers:key=Co-Authored-By,valueonly,separator=%x2c)%x1e"

    static func commits(_ out: String) -> [Commit] {
        out.components(separatedBy: rs).compactMap { rec in
            let f = rec.trimmingCharacters(in: .newlines).components(separatedBy: us)
            guard f.count >= 7, f[0].count >= 40 else { return nil }
            let co = f.count > 7 ? f[7].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } : []
            return Commit(hash: f[0], parents: f[1].split(separator: " ").map(String.init), author: f[2], email: f[3],
                          date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                          refs: f[5].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                          subject: f[6], coAuthors: co)
        }
    }

    /// `git status --porcelain=v1 -z --branch`
    static func status(_ out: String) -> RepoStatus {
        var st = RepoStatus()
        var parts = out.components(separatedBy: "\0")
        if let first = parts.first, first.hasPrefix("## ") {
            parts.removeFirst()
            var line = String(first.dropFirst(3))
            if let r = line.range(of: " [") {
                let meta = line[r.upperBound...].dropLast()
                for item in meta.split(separator: ",") {
                    let t = item.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("ahead ") { st.ahead = Int(t.dropFirst(6)) ?? 0 }
                    if t.hasPrefix("behind ") { st.behind = Int(t.dropFirst(7)) ?? 0 }
                }
                line = String(line[..<r.lowerBound])
            }
            if let r = line.range(of: "...") { st.branch = String(line[..<r.lowerBound]); st.upstream = String(line[r.upperBound...]) }
            else { st.branch = line.replacingOccurrences(of: "No commits yet on ", with: "") }
        }
        var i = 0
        while i < parts.count {
            let e = parts[i]; i += 1
            guard e.count > 3 else { continue }
            let x = e[e.startIndex], y = e[e.index(after: e.startIndex)]
            let path = String(e.dropFirst(3))
            var old: String?
            if x == "R" || x == "C" || y == "R" || y == "C", i < parts.count { old = parts[i]; i += 1 }
            if x == "?" && y == "?" { st.changes.append(.init(path: path, oldPath: nil, kind: .untracked, staged: false)); continue }
            let conflict = x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D")
            if conflict { st.changes.append(.init(path: path, oldPath: nil, kind: .conflicted, staged: false)); continue }
            if x != " " { st.changes.append(.init(path: path, oldPath: old, kind: ChangeKind(rawValue: String(x)) ?? .unknown, staged: true)) }
            if y != " " { st.changes.append(.init(path: path, oldPath: old, kind: ChangeKind(rawValue: String(y)) ?? .unknown, staged: false)) }
        }
        return st
    }

    static func diff(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        let chunks = text.components(separatedBy: "\ndiff --git ")
        for (idx, raw) in chunks.enumerated() {
            let chunk = idx == 0 ? (raw.hasPrefix("diff --git ") ? String(raw.dropFirst(11)) : raw) : raw
            guard !chunk.isEmpty, idx > 0 || raw.hasPrefix("diff --git ") else { continue }
            let lines = chunk.components(separatedBy: "\n")
            let head = lines[0]
            var path = head.components(separatedBy: " b/").last ?? head
            if let plus = lines.first(where: { $0.hasPrefix("+++ b/") }) { path = String(plus.dropFirst(6)) }
            let binary = lines.contains { $0.hasPrefix("Binary files") || $0.hasPrefix("GIT binary patch") }
            var hunks: [DiffHunk] = []
            var headerLines: [String] = []
            var cur: (h: String, ls: [DiffLine], raw: [String])?
            var oldN = 0, newN = 0, lid = 0
            func closeHunk() { if let c = cur { hunks.append(.init(id: hunks.count, header: c.h, lines: c.ls, patch: c.raw.joined(separator: "\n") + "\n")) }; cur = nil }
            for l in lines.dropFirst() {
                if l.hasPrefix("@@") {
                    closeHunk()
                    let nums = l.split(separator: " ").dropFirst().prefix(2).map { $0.dropFirst().split(separator: ",")[0] }
                    oldN = Int(nums.first ?? "0") ?? 0; newN = Int(nums.last ?? "0") ?? 0
                    cur = (l, [], [l])
                } else if cur != nil {
                    guard let c = l.first else { if !l.isEmpty || true { /* trailing empty */ }; continue }
                    lid += 1
                    switch c {
                    case "+": cur!.ls.append(.init(id: lid, kind: .added, text: String(l.dropFirst()), oldLine: nil, newLine: newN)); newN += 1
                    case "-": cur!.ls.append(.init(id: lid, kind: .removed, text: String(l.dropFirst()), oldLine: oldN, newLine: nil)); oldN += 1
                    case "\\": break
                    default: cur!.ls.append(.init(id: lid, kind: .context, text: String(l.dropFirst()), oldLine: oldN, newLine: newN)); oldN += 1; newN += 1
                    }
                    cur!.raw.append(l)
                } else { headerLines.append(l) }
            }
            closeHunk()
            files.append(.init(path: path, hunks: hunks, isBinary: binary, header: "diff --git " + head + "\n" + headerLines.joined(separator: "\n")))
        }
        return files
    }
}
