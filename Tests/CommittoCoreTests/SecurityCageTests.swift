import XCTest
@testable import CommittoCore

final class SecurityCageTests: XCTestCase {
    func testNodeVersionGate() {
        XCTAssertTrue(SecurityCageManager.nodeAtLeastMin("v22.22.0"))
        XCTAssertTrue(SecurityCageManager.nodeAtLeastMin("22.18.0\n"))
        XCTAssertFalse(SecurityCageManager.nodeAtLeastMin("v22.17.9"))
        XCTAssertFalse(SecurityCageManager.nodeAtLeastMin("v20.11.0"))
        XCTAssertFalse(SecurityCageManager.nodeAtLeastMin("garbage"))
    }

    func testParsePlanJSON() {
        let json = """
        {"signals":[{"id":"u","check":"unguarded-mutation","severity":"high","certainty":"worth-a-look","what":"1 endpoint changes data","why":"anyone can call it","action":"add a check","fixPrompt":"fix it","locations":[{"path":"a/route.ts"},{"path":"b/route.ts","line":7}]},
        {"id":"c","check":"idor","severity":"high","certainty":"confirmed","what":"IDOR","why":"w","action":"a","locations":[{"path":"c.ts"}]}],
        "surfaces":4,"estimate":{"lowUsd":0.02,"highUsd":0.15},"rules":{"ran":false},"notices":["n1"],"changes":{"surfaces":["a/route.ts#POST /x"]}}
        """
        let r = SecurityCageManager.parse(JSONValue.parse(json)!, outDir: "/o")
        XCTAssertEqual(r.findings.count, 3)
        XCTAssertEqual(r.findings.first?.certainty, "confirmed", "confirmed items sort first within a severity")
        XCTAssertEqual(r.findings.first { $0.file == "b/route.ts" }?.line, 7)
        XCTAssertEqual(r.findings.first?.source, "securitycage")
        XCTAssertEqual(r.surfaces, 4); XCTAssertEqual(r.changedSurfaces.count, 1); XCTAssertEqual(r.estimateUSD, 0.02...0.15)
    }

    func testWorkflowIsPinnedAndSafe() {
        let y = SecurityCageManager.workflowYAML(sha: "35ea2b3a4149a8770c6c2b15cd9f5ffbd25a102e")
        XCTAssertTrue(y.contains("kalahroudi/securitycage@35ea2b3a4149a8770c6c2b15cd9f5ffbd25a102e"))
        XCTAssertTrue(y.contains("on: pull_request "))
        XCTAssertFalse(y.contains("pull_request_target:"))
    }

    /// Live install/update/rollback against GitHub. Opt in: COMMITTO_NETWORK_TESTS=1
    func testInstallUpdateRollbackLive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMMITTO_NETWORK_TESTS"] == "1", "network test")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = SecurityCageManager(root: root)
        let old = "7115e618c171b5ae845d1e56df397fac6d99b9b8"
        let p1 = try await m.install(sha: old)
        XCTAssertEqual(p1.sha, old); XCTAssertEqual(m.pin()?.sha, old)
        let upd = try await m.checkForUpdate()
        XCTAssertNotNil(upd, "an older pin must report an update")
        XCTAssertGreaterThanOrEqual(upd?.commitsBehind ?? 0, 1)
        let p2 = try await m.update()
        XCTAssertNotEqual(p2.sha, old)
        try m.rollback()
        XCTAssertEqual(m.pin()?.sha, old)
        let none = try await m.install(sha: p2.sha).sha
        XCTAssertEqual(none, p2.sha)
        let dirty = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString)/src/app/api/x")
        try FileManager.default.createDirectory(at: dirty, withIntermediateDirectories: true)
        try SecurityCageManager.fixtureRoute.write(to: dirty.appendingPathComponent("route.ts"), atomically: true, encoding: .utf8)
        let repo = dirty.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try "{\"name\":\"v\",\"dependencies\":{\"next\":\"15.0.0\"}}".write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let res = try await m.plan(repo: repo, changed: ["src/app/api/x/route.ts"])
        XCTAssertFalse(res.findings.isEmpty)
    }
}
