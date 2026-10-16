import Foundation

public struct PatchError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Builds a partial patch from one hunk so individual added/removed lines can be staged, unstaged or discarded.
///
/// Forward (staging, applied to the index): an unselected `+` line is left out, an unselected `-` line becomes context.
/// Reverse (unstaging or discarding, applied with `-R` to the side that already contains the change): an unselected `+`
/// line becomes context (it stays), an unselected `-` line is left out (it stays removed).
/// Hunk counts are recomputed; `git apply` validates the context, so a wrong patch fails instead of landing in the wrong place.
public enum PatchBuilder {
    public static func patch(file: FileDiff, hunk: DiffHunk, selected: Set<Int>, reverse: Bool) throws -> String {
        guard hunk.lines.contains(where: { $0.kind != .context && selected.contains($0.id) }) else {
            throw PatchError(message: "No changed lines selected")
        }
        guard let (oldStart, newStart, section) = parseHeader(hunk.header) else {
            throw PatchError(message: "Unreadable hunk header: \(hunk.header)")
        }
        var body: [String] = []
        var oldCount = 0, newCount = 0
        func emit(_ prefix: Character, _ l: DiffLine) {
            body.append(String(prefix) + l.text)
            if l.noNewlineAtEnd { body.append("\\ No newline at end of file") }
            if prefix != "+" { oldCount += 1 }
            if prefix != "-" { newCount += 1 }
        }
        for l in hunk.lines {
            switch l.kind {
            case .context: emit(" ", l)
            case .added:
                if selected.contains(l.id) { emit("+", l) } else if reverse { emit(" ", l) }
            case .removed:
                if selected.contains(l.id) { emit("-", l) } else if !reverse { emit(" ", l) }
            case .header: break
            }
        }
        let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" + section
        return file.header + "\n" + header + "\n" + body.joined(separator: "\n") + "\n"
    }

    /// `@@ -a,b +c,d @@ section` (counts optional). Returns the starts and the trailing section text including its leading space.
    static func parseHeader(_ h: String) -> (Int, Int, String)? {
        guard h.hasPrefix("@@ -"), let end = h.range(of: " @@", range: h.index(h.startIndex, offsetBy: 3)..<h.endIndex) else { return nil }
        let nums = h[h.index(h.startIndex, offsetBy: 3)..<end.lowerBound].split(separator: " ")
        guard nums.count == 2, nums[0].hasPrefix("-"), nums[1].hasPrefix("+"),
              let a = Int(nums[0].dropFirst().split(separator: ",")[0]), let c = Int(nums[1].dropFirst().split(separator: ",")[0]) else { return nil }
        return (a, c, String(h[end.upperBound...]))
    }
}
