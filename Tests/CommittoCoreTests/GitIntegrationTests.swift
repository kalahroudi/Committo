import XCTest
@testable import CommittoCore

final class GitIntegrationTests: XCTestCase {
    var dir: URL!
    var repo: GitRepository!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("committo-\(UUID().uuidString)")
        try await GitRepository.initialize(at: dir)
        repo = GitRepository(url: dir)
        for (k, v) in [("user.name", "Test"), ("user.email", "t@example.com"), ("commit.gpgsign", "false")] { _ = try await Shell.check("git", ["config", k, v], cwd: dir) }
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ s: String) throws { try s.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }

    func testStatusStageCommitLogAndGraph() async throws {
        try write("a.txt", "one\n")
        var st = try await repo.status()
        XCTAssertEqual(st.unstaged.first?.kind, .untracked)
        try await repo.stageAll(); try await repo.commit("first")
        try await repo.createBranch("feature")
        try write("b.txt", "b\n"); try await repo.stageAll(); try await repo.commit("on feature")
        try await repo.checkout("main")
        try write("c.txt", "c\n"); try await repo.stageAll(); try await repo.commit("on main")
        try await repo.merge("feature")
        st = try await repo.status()
        XCTAssertTrue(st.isClean)
        let log = try await repo.log()
        XCTAssertEqual(log.count, 4)
        XCTAssertTrue(log[0].isMerge)
        let rows = CommitGraph.layout(log)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.laneCount).max(), 2)
        let branches = try await repo.branches()
        XCTAssertTrue(branches.contains { $0.name == "main" && $0.isCurrent })
    }

    func testHunkStaging() async throws {
        try write("f.txt", (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try await repo.stageAll(); try await repo.commit("base")
        var lines = (1...30).map { "line \($0)" }
        lines[1] = "CHANGED 2"; lines[27] = "CHANGED 28"
        try write("f.txt", lines.joined(separator: "\n") + "\n")
        let d = try await repo.diff(path: "f.txt").first!
        XCTAssertEqual(d.hunks.count, 2)
        try await repo.applyPatch(d.header + "\n" + d.hunks[0].patch)
        let staged = try await repo.diff(path: "f.txt", staged: true).first!
        XCTAssertEqual(staged.hunks.count, 1)
        XCTAssertTrue(staged.hunks[0].lines.contains { $0.text == "CHANGED 2" })
        let rest = try await repo.diff(path: "f.txt").first!
        XCTAssertTrue(rest.hunks[0].lines.contains { $0.text == "CHANGED 28" })
    }

    func testStashAndLensAttribution() async throws {
        try write("a.txt", "x\n"); try await repo.stageAll(); try await repo.commit("base")
        try await repo.createBranch("claude/add-thing")
        try write("t.txt", "t\n"); try await repo.stageAll()
        try await repo.commit("add thing\n\nCo-Authored-By: Claude <noreply@anthropic.com>")
        try await repo.checkout("main")
        let items = await AgentLens.scan(repo, base: "main")
        XCTAssertEqual(items.first?.agent, .claude)
        XCTAssertEqual(items.first?.commits.count, 1)
        XCTAssertEqual(items.first?.filesChanged, 1)
        try write("a.txt", "dirty\n")
        try await repo.stashPush()
        let stashes = try await repo.stashes()
        XCTAssertEqual(stashes.count, 1)
    }

    func testMCPStatusTool() async throws {
        try write("a.txt", "x\n")
        let s = MCPServer()
        let r = await s.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "repo_status", "arguments": ["repo": .string(dir.path)]]])
        XCTAssertTrue(r?["result"]?["content"]?[0]?["text"]?.string?.contains("a.txt") == true)
    }
}
