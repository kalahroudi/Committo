import XCTest
@testable import CommittoCore

/// Deterministic RNG so a failing seed can be replayed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class PatchBuilderUnitTests: XCTestCase {
    func hunk(_ lines: [(DiffLine.Kind, String)], header: String = "@@ -1,3 +1,3 @@") -> (FileDiff, DiffHunk) {
        let dl = lines.enumerated().map { DiffLine(id: $0.offset, kind: $0.element.0, text: $0.element.1, oldLine: nil, newLine: nil) }
        let h = DiffHunk(id: 0, header: header, lines: dl, patch: "")
        return (FileDiff(path: "f", hunks: [h], isBinary: false, header: "diff --git a/f b/f\n--- a/f\n+++ b/f"), h)
    }
    func testForwardDropsUnselectedAddedAndKeepsUnselectedRemovedAsContext() throws {
        let (f, h) = hunk([(.context, "a"), (.removed, "b"), (.added, "B"), (.added, "C"), (.context, "z")])
        let p = try PatchBuilder.patch(file: f, hunk: h, selected: [2], reverse: false)   // only +B
        XCTAssertTrue(p.hasSuffix("@@ -1,3 +1,4 @@\n a\n b\n+B\n z\n"), p)
    }
    func testReverseKeepsUnselectedAddedAsContextAndDropsUnselectedRemoved() throws {
        let (f, h) = hunk([(.context, "a"), (.removed, "b"), (.added, "B"), (.added, "C"), (.context, "z")])
        let p = try PatchBuilder.patch(file: f, hunk: h, selected: [3], reverse: true)    // only +C
        XCTAssertTrue(p.hasSuffix("@@ -1,3 +1,4 @@\n a\n B\n+C\n z\n"), p)   // old side: a,B,z   new side: a,B,C,z
    }
    func testNothingSelectedThrows() {
        let (f, h) = hunk([(.context, "a"), (.added, "x")])
        XCTAssertThrowsError(try PatchBuilder.patch(file: f, hunk: h, selected: [], reverse: false))
        XCTAssertThrowsError(try PatchBuilder.patch(file: f, hunk: h, selected: [0], reverse: false), "context line is not a change")
    }
    func testHeaderParsing() {
        XCTAssertEqual(PatchBuilder.parseHeader("@@ -12,5 +14,6 @@ func foo()")?.0, 12)
        XCTAssertEqual(PatchBuilder.parseHeader("@@ -12,5 +14,6 @@ func foo()")?.1, 14)
        XCTAssertEqual(PatchBuilder.parseHeader("@@ -12,5 +14,6 @@ func foo()")?.2, " func foo()")
        XCTAssertEqual(PatchBuilder.parseHeader("@@ -3 +3 @@")?.0, 3)
        XCTAssertNil(PatchBuilder.parseHeader("garbage"))
    }
}

final class LineStagingIntegrationTests: XCTestCase {
    var dir: URL!
    var repo: GitRepository!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("committo-lines-\(UUID().uuidString)")
        try await GitRepository.initialize(at: dir)
        repo = GitRepository(url: dir)
        for (k, v) in [("user.name", "T"), ("user.email", "t@example.com"), ("commit.gpgsign", "false")] { _ = try await Shell.check("git", ["config", k, v], cwd: dir) }
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ s: String) throws { try s.write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8) }
    func read() throws -> String { try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8) }
    func indexContent() async throws -> String { try await Shell.check("git", ["show", ":f.txt"], cwd: dir) }
    func tree() async throws -> String { try await Shell.check("git", ["write-tree"], cwd: dir).trimmingCharacters(in: .whitespacesAndNewlines) }
    func lines(_ s: String) -> [String] { var l = s.components(separatedBy: "\n"); if l.last == "" { l.removeLast() }; return l }
    func text(_ l: [String]) -> String { l.joined(separator: "\n") + "\n" }

    /// A random old file and an edited copy (deletes, replacements, insertions), both newline-terminated.
    func randomPair(_ rng: inout SplitMix64) -> (old: [String], new: [String]) {
        let n = Int.random(in: 12...40, using: &rng)
        let old = (1...n).map { "line \($0)" }
        var new = old
        var changed = false
        var serial = 0
        for _ in 0..<Int.random(in: 1...8, using: &rng) {
            guard !new.isEmpty else { break }
            let i = Int.random(in: 0..<new.count, using: &rng)
            serial += 1
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: new.remove(at: i); changed = true
            case 1: new[i] = "edited \(serial)"; changed = true
            default: new.insert("inserted \(serial)", at: i); changed = true
            }
        }
        if !changed || new == old { new.append("tail") }
        return (old, new)
    }

    /// Expected file after applying only `selected` lines of hunk `chosen`; every other hunk is left as in `base`.
    /// `reverse == false`: base is the old side, selected changes are applied. `reverse == true`: base is the new side
    /// (index or work tree already containing every change) and selected changes are undone.
    func model(file: FileDiff, old: [String], new: [String], chosen: Int, selected: Set<Int>, reverse: Bool) -> [String] {
        var out: [String] = []
        var p = 1                                  // next line number of `base` to copy
        let base = reverse ? new : old
        for (hi, h) in file.hunks.enumerated() {
            let start = PatchBuilder.parseHeader(h.header)!
            let first = reverse ? start.1 : start.0
            while p < first { out.append(base[p - 1]); p += 1 }
            for l in h.lines {
                let pick = hi == chosen && selected.contains(l.id)
                switch l.kind {
                case .context: out.append(l.text); p += 1
                case .added:
                    if reverse { if pick { /* undo: drop */ } else { out.append(l.text) }; p += 1 }
                    else if pick { out.append(l.text) }
                case .removed:
                    if reverse { if pick { out.append(l.text) } }
                    else { if pick { /* applied: drop */ } else { out.append(l.text) }; p += 1 }
                case .header: break
                }
            }
        }
        while p <= base.count { out.append(base[p - 1]); p += 1 }
        return out
    }

    func changed(_ h: DiffHunk) -> [Int] { h.lines.filter { $0.kind != .context }.map(\.id) }

    func testRandomStagingMatchesModelAndUndoRestoresTree() async throws {
        var rng = SplitMix64(state: 0xC0FFEE)
        for iter in 0..<40 {
            let (old, new) = randomPair(&rng)
            try write(text(old)); try await repo.stageAll(); try await repo.commit("base \(iter)")
            let headTree = try await tree()
            try write(text(new))
            let file = try await repo.diff(path: "f.txt").first!
            let ci = Int.random(in: 0..<file.hunks.count, using: &rng)
            let ids = changed(file.hunks[ci])
            var picked = ids.filter { _ in Bool.random(using: &rng) }
            if picked.isEmpty { picked = [ids[0]] }
            let sel = Set(picked)
            let ctx = "iter \(iter) hunk \(ci) selected \(sel.sorted())"

            try await repo.stageLines(file, hunk: file.hunks[ci], lines: sel)
            let expected = text(model(file: file, old: old, new: new, chosen: ci, selected: sel, reverse: false))
            let staged = try await indexContent()
            XCTAssertEqual(staged, expected, ctx)
            let wt = try read()
            XCTAssertEqual(wt, text(new), "work tree must not change: " + ctx)

            // Undo: unstage exactly what was staged -> index tree equals HEAD again.
            var guardCount = 0
            while let sf = try await repo.diff(path: "f.txt", staged: true).first, guardCount < 10 {
                guardCount += 1
                try await repo.unstageLines(sf, hunk: sf.hunks[0], lines: Set(changed(sf.hunks[0])))
            }
            let afterUndo = try await tree()
            XCTAssertEqual(afterUndo, headTree, "undo-equality: " + ctx)
            try await repo.commitAllForTest(new: new)      // advance so the next iteration starts from a clean base
        }
    }

    func testRandomPartialUnstageAndDiscardMatchModel() async throws {
        var rng = SplitMix64(state: 0xBADCAB1E)
        for iter in 0..<40 {
            let (old, new) = randomPair(&rng)
            try write(text(old)); try await repo.stageAll(); try await repo.commit("base \(iter)")

            // --- unstage a subset of a fully staged change
            try write(text(new)); try await repo.stageAll()
            var sf = try await repo.diff(path: "f.txt", staged: true).first!
            var ci = Int.random(in: 0..<sf.hunks.count, using: &rng)
            var ids = changed(sf.hunks[ci])
            var sel = Set(ids.filter { _ in Bool.random(using: &rng) })
            if sel.isEmpty { sel = [ids[0]] }
            try await repo.unstageLines(sf, hunk: sf.hunks[ci], lines: sel)
            let idxU = try await indexContent()
            XCTAssertEqual(idxU, text(model(file: sf, old: old, new: new, chosen: ci, selected: sel, reverse: true)), "unstage iter \(iter) hunk \(ci) \(sel.sorted())")
            XCTAssertEqual(try read(), text(new))

            // --- discard a subset from the work tree (reset index to HEAD first)
            _ = try await Shell.check("git", ["reset", "-q"], cwd: dir)
            sf = try await repo.diff(path: "f.txt").first!
            ci = Int.random(in: 0..<sf.hunks.count, using: &rng)
            ids = changed(sf.hunks[ci])
            sel = Set(ids.filter { _ in Bool.random(using: &rng) })
            if sel.isEmpty { sel = [ids[0]] }
            try await repo.discardLines(sf, hunk: sf.hunks[ci], lines: sel)
            XCTAssertEqual(try read(), text(model(file: sf, old: old, new: new, chosen: ci, selected: sel, reverse: true)), "discard iter \(iter) hunk \(ci) \(sel.sorted())")
            _ = try await Shell.check("git", ["checkout", "-q", "--", "f.txt"], cwd: dir)
        }
    }

    func testFileWithoutTrailingNewline() async throws {
        try write("a\nb"); try await repo.stageAll(); try await repo.commit("base")       // no EOL
        try write("a\nB")                                                                   // still no EOL
        let f = try await repo.diff(path: "f.txt").first!
        let ids = Set(changed(f.hunks[0]))
        XCTAssertTrue(f.hunks[0].lines.contains { $0.noNewlineAtEnd })
        try await repo.stageLines(f, hunk: f.hunks[0], lines: ids)
        let idxB = try await indexContent()
        XCTAssertEqual(idxB, "a\nB")
        // and unstage it again
        let sf = try await repo.diff(path: "f.txt", staged: true).first!
        try await repo.unstageLines(sf, hunk: sf.hunks[0], lines: Set(changed(sf.hunks[0])))
        let idxb = try await indexContent()
        XCTAssertEqual(idxb, "a\nb")
    }

    func testStaleDiffFailsAndLeavesIndexUntouched() async throws {
        try write(text((1...20).map { "line \($0)" })); try await repo.stageAll(); try await repo.commit("base")
        var l = (1...20).map { "line \($0)" }; l[9] = "changed"
        try write(text(l))
        let f = try await repo.diff(path: "f.txt").first!
        // file changes underneath the diff the user is looking at
        l[9] = "changed differently"; l[8] = "also changed"
        try write(text(l))
        _ = try await Shell.check("git", ["add", "f.txt"], cwd: dir)
        let before = try await tree()
        do { try await repo.stageLines(f, hunk: f.hunks[0], lines: Set(changed(f.hunks[0]))); XCTFail("expected git apply to reject the stale patch") } catch {}
        let after = try await tree()
        XCTAssertEqual(after, before)
    }

    func testEmptySelectionThrowsBeforeTouchingGit() async throws {
        try write("a\nb\n"); try await repo.stageAll(); try await repo.commit("base")
        try write("a\nB\n")
        let f = try await repo.diff(path: "f.txt").first!
        do { try await repo.stageLines(f, hunk: f.hunks[0], lines: []); XCTFail() } catch is PatchError {}
    }
}

extension GitRepository {
    /// Test helper: make HEAD contain `new` so the next iteration diffs against it.
    func commitAllForTest(new: [String]) async throws {
        try await stageAll()
        _ = try? await Shell.check("git", ["commit", "-q", "-m", "advance"], cwd: url)
    }
}
