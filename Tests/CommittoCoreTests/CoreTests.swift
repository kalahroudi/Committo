import XCTest
@testable import CommittoCore

final class CoreTests: XCTestCase {
    func commit(_ h: String, _ p: [String]) -> Commit {
        Commit(hash: h, parents: p, author: "a", email: "a@x", date: Date(), refs: [], subject: h, coAuthors: [])
    }

    func testLinearGraphUsesOneLane() {
        let rows = CommitGraph.layout([commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])
        XCTAssertEqual(rows.map(\.nodeLane), [0, 0, 0])
        XCTAssertEqual(rows.last?.after.count, 0)
    }

    func testMergeOpensSecondLane() {
        // m merges (b, c); both descend from a.
        let rows = CommitGraph.layout([commit("m", ["b", "c"]), commit("b", ["a"]), commit("c", ["a"]), commit("a", [])])
        XCTAssertEqual(rows[0].after.compactMap { $0 }.sorted(), ["b", "c"])
        XCTAssertEqual(rows[1].nodeLane, 0)
        XCTAssertEqual(rows[2].nodeLane, 1)
        XCTAssertEqual(rows[3].mergeLanes.count, 0)
    }

    func testStatusParsing() {
        let out = "## main...origin/main [ahead 2, behind 1]\0 M a.txt\0A  b.txt\0R  new.txt\0old.txt\0?? c.txt\0"
        let st = GitParse.status(out)
        XCTAssertEqual(st.branch, "main"); XCTAssertEqual(st.ahead, 2); XCTAssertEqual(st.behind, 1)
        XCTAssertEqual(st.staged.count, 2); XCTAssertEqual(st.unstaged.count, 2)
        XCTAssertEqual(st.changes.first { $0.path == "new.txt" }?.oldPath, "old.txt")
    }

    func testDiffParsing() {
        let d = "diff --git a/f.txt b/f.txt\nindex 1..2 100644\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n"
        let files = GitParse.diff(d)
        XCTAssertEqual(files.count, 1); XCTAssertEqual(files[0].additions, 1); XCTAssertEqual(files[0].deletions, 1)
    }

    func testScannerFindsSecretsOnlyInAddedLines() {
        let d = "diff --git a/x.py b/x.py\n--- a/x.py\n+++ b/x.py\n@@ -1,1 +1,2 @@\n-AKIAABCDEFGHIJKLMNOP\n+key = 'AKIAABCDEFGHIJKLMNOP'\n"
        let f = SecurityScanner().scan(diff: GitParse.diff(d))
        XCTAssertEqual(f.filter { $0.rule == "secret.aws-key" }.count, 1)
        XCTAssertTrue(f[0].snippet.contains("redacted"))
    }

    func testAgentDetection() {
        XCTAssertEqual(AgentKind.detect(branch: "claude/fix-x"), .claude)
        XCTAssertEqual(AgentKind.detect(coAuthors: ["Claude <noreply@anthropic.com>"]), .claude)
        XCTAssertEqual(AgentKind.detect(author: "Jane"), .human)
    }

    func testActListParsing() {
        let t = "Stage  Job ID  Job name  Workflow name  Workflow file  Events\n0      build    build     CI             ci.yml         push,pull_request\n"
        let w = ActRunner.parseList(t)
        XCTAssertEqual(w.first?.job, "build"); XCTAssertEqual(w.first?.file, "ci.yml")
    }

    func testMCPInitializeAndList() async {
        let s = MCPServer()
        let r = await s.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        XCTAssertGreaterThan(r?["result"]?["tools"]?.array?.count ?? 0, 5)
    }
}
