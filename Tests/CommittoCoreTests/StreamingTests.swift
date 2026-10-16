import XCTest
@testable import CommittoCore

final class RecordSplitterTests: XCTestCase {
    func collect(_ chunks: [String], sep: UInt8 = 0x0A, max: Int = 1 << 20) -> [(String, Bool)] {
        let box = Box()
        let s = RecordSplitter(separator: sep, maxRecord: max) { d, t in box.add((String(decoding: d, as: UTF8.self), t)) }
        chunks.forEach { s.feed(Data($0.utf8)) }
        s.finish()
        return box.items
    }
    final class Box: @unchecked Sendable { var items: [(String, Bool)] = []; func add(_ x: (String, Bool)) { items.append(x) } }

    func testResultIsIndependentOfChunkBoundaries() {
        let text = "alpha\nbeta\n\ngamma"
        let whole = collect([text]).map(\.0)
        XCTAssertEqual(whole, ["alpha", "beta", "", "gamma"])
        for cut in 1..<text.utf8.count {
            let a = String(text.prefix(cut)), b = String(text.dropFirst(cut))
            XCTAssertEqual(collect([a, b]).map(\.0), whole, "cut at \(cut)")
        }
        XCTAssertEqual(collect(text.map { String($0) }).map(\.0), whole)
    }
    func testTrailingSeparatorDoesNotAddEmptyRecord() { XCTAssertEqual(collect(["a\nb\n"]).map(\.0), ["a", "b"]) }
    func testOverlongRecordIsCutAndFlagged() {
        let r = collect([String(repeating: "x", count: 50) + "\nok\n"], max: 10)
        XCTAssertEqual(r.map(\.0), [String(repeating: "x", count: 10), "ok"])
        XCTAssertEqual(r.map(\.1), [true, false])
    }
    func testNulSeparator() { XCTAssertEqual(collect(["a\0b\0"], sep: 0).map(\.0), ["a", "b"]) }
}

final class StatusParserTests: XCTestCase {
    func testRenameCopyAndPlainEntries() {
        let st = GitParse.status("## main...origin/main [ahead 2, behind 1]\0R  new.txt\0old.txt\0 M a.txt\0?? u.txt\0UU c.txt\0")
        XCTAssertEqual(st.branch, "main"); XCTAssertEqual(st.upstream, "origin/main"); XCTAssertEqual(st.ahead, 2); XCTAssertEqual(st.behind, 1)
        XCTAssertEqual(st.changes.count, 4)
        XCTAssertEqual(st.changes[0].oldPath, "old.txt"); XCTAssertEqual(st.changes[0].path, "new.txt"); XCTAssertTrue(st.changes[0].staged)
        XCTAssertEqual(st.changes[1].kind, .modified)
        XCTAssertEqual(st.changes[2].kind, .untracked)
        XCTAssertEqual(st.changes[3].kind, .conflicted)
    }
    func testDanglingRenameFromTruncatedOutputIsKept() {
        let st = GitParse.status("## main\0R  new.txt")
        XCTAssertEqual(st.changes.map(\.path), ["new.txt"])
        XCTAssertNil(st.changes[0].oldPath)
    }
}

final class DiffParserTests: XCTestCase {
    func sample(lines: Int) -> String {
        "diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,\(lines) +1,\(lines) @@\n"
        + (1...lines).map { "+line \($0)" }.joined(separator: "\n") + "\n"
        + "diff --git a/b.bin b/b.bin\nindex 1..2 100644\nBinary files a/b.bin and b/b.bin differ\n"
    }
    func testFilesHunksAndBinary() {
        let f = GitParse.diff(sample(lines: 3))
        XCTAssertEqual(f.map(\.path), ["a.txt", "b.bin"])
        XCTAssertEqual(f[0].additions, 3); XCTAssertFalse(f[0].isTruncated)
        XCTAssertTrue(f[1].isBinary); XCTAssertTrue(f[1].hunks.isEmpty)
    }
    func testPerFileLineCapTruncatesAndDoesNotAffectNextFile() {
        let f = GitParse.diff(sample(lines: 100), maxLinesPerFile: 10)
        XCTAssertEqual(f[0].additions, 10)
        XCTAssertTrue(f[0].isTruncated)
        XCTAssertEqual(f[1].path, "b.bin"); XCTAssertFalse(f[1].isTruncated)
    }
    func testPlusPlusPlusInsideAHunkDoesNotRenameTheFile() {
        let d = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1,1 @@\n++ b/not-a-path\n"
        XCTAssertEqual(GitParse.diff(d).first?.path, "x")
    }
}

final class GitStreamingIntegrationTests: XCTestCase {
    var dir: URL!
    var repo: GitRepository!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("committo-stream-\(UUID().uuidString)")
        try await GitRepository.initialize(at: dir)
        repo = GitRepository(url: dir)
        for (k, v) in [("user.name", "T"), ("user.email", "t@example.com"), ("commit.gpgsign", "false")] { _ = try await Shell.check("git", ["config", k, v], cwd: dir) }
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        let end = Date().addingTimeInterval(5)
        while ProcessSupervisor.shared.liveCount > 0 && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(ProcessSupervisor.shared.liveCount, 0, "git processes left running")
    }
    func write(_ name: String, _ s: String) throws { try s.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }

    func testLogStopsAtLimitAndPagesCorrectly() async throws {
        for i in 1...40 { try write("f.txt", "\(i)\n"); try await repo.stageAll(); try await repo.commit("c\(i)") }
        let page = try await repo.log(limit: 7)
        XCTAssertEqual(page.count, 7)
        XCTAssertEqual(page.first?.subject, "c40")
        let all = try await repo.log(limit: 500)
        XCTAssertEqual(all.count, 40)
    }

    func testLogOfEmptyRepoIsEmpty() async throws { let l = try await repo.log(); XCTAssertTrue(l.isEmpty) }

    func testHugeDiffIsTruncatedPerFile() async throws {
        try write("big.txt", (1...30_000).map { "old \($0)" }.joined(separator: "\n") + "\n")
        try await repo.stageAll(); try await repo.commit("base")
        try write("big.txt", (1...30_000).map { "new \($0)" }.joined(separator: "\n") + "\n")
        let files = try await repo.diff()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isTruncated)
        XCTAssertEqual(files[0].hunks.flatMap(\.lines).count, DiffParser.defaultMaxLinesPerFile)
    }

    func testTotalDiffByteCapStopsGitAndFlagsLastFile() async throws {
        try write("a.txt", String(repeating: "a\n", count: 5000)); try await repo.stageAll(); try await repo.commit("base")
        try write("a.txt", String(repeating: "b\n", count: 5000))
        let files = try await repo.parseDiff(["diff", "--no-color"], maxBytes: 2_000)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isTruncated)
    }

    func testUntrackedFileContentIsCapped() throws {
        try write("huge.log", String(repeating: "0123456789\n", count: 200_000))   // 2.2 MB
        let d = repo.untrackedContent("huge.log", maxBytes: 100_000)
        XCTAssertEqual(d?.isTruncated, true)
        XCTAssertLessThan(d?.hunks.first?.lines.count ?? .max, 20_000)
    }

    func testStatusWithManyUntrackedFiles() async throws {
        for i in 0..<2_000 { try write("u\(i).txt", "x") }
        let st = try await repo.status()
        XCTAssertEqual(st.changes.filter { $0.kind == .untracked }.count, 2_000)
    }

    func testRecordsStreamEndsEarlyAndKillsProcess() async throws {
        var n = 0
        for try await _ in Shell.records("sh", ["-c", "yes"]) { n += 1; if n == 5 { break } }
        let end = Date().addingTimeInterval(5)
        while ProcessSupervisor.shared.liveCount > 0 && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(ProcessSupervisor.shared.liveCount, 0)
    }

    func testRecordsReportsStderrOnFailure() async throws {
        do { for try await _ in Shell.records("sh", ["-c", "echo boom >&2; exit 4"]) {}; XCTFail() }
        catch let e as ShellError { XCTAssertEqual(e.result.status, 4); XCTAssertTrue(e.result.stderr.contains("boom")) }
    }
}
