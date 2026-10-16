import XCTest
@testable import CommittoCore

/// Real git: `upstream` and the fork's `origin` are local bare repos; `local` is a clone of the fork.
final class ForkTests: XCTestCase {
    var root: URL!
    var saved: [String: String?] = [:]
    var env: [String: String] {
        ["HOME": root.path, "GIT_CONFIG_GLOBAL": root.appendingPathComponent("gitconfig").path, "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"]
    }
    var upstreamBare: URL { root.appendingPathComponent("upstream.git") }
    var originBare: URL { root.appendingPathComponent("origin.git") }
    var upstreamWork: URL { root.appendingPathComponent("upstream-work") }
    var local: URL { root.appendingPathComponent("local") }
    var repo: GitRepository { GitRepository(url: local) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("committo-fork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The test process must see the same isolated config for the code under test.
        for (k, v) in env { saved[k] = getenv(k).map { String(cString: $0) }; setenv(k, v, 1) }
        try await sh(root, ["init", "-q", "--bare", "-b", "main", upstreamBare.path])
        try await sh(root, ["clone", "-q", upstreamBare.path, upstreamWork.path])
        try await sh(upstreamWork, ["checkout", "-q", "-b", "main"])
        try await commit(upstreamWork, "base.txt", "base\n", "base")
        try await sh(upstreamWork, ["push", "-q", "origin", "main"])
        try await sh(root, ["clone", "-q", "--bare", upstreamBare.path, originBare.path])   // the "fork"
        try await sh(root, ["clone", "-q", originBare.path, local.path])
        _ = try await repo.configureFork(upstreamURL: upstreamBare.path)
    }
    override func tearDown() async throws {
        for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    func sh(_ dir: URL, _ args: [String]) async throws -> String { try await Shell.check("git", args, cwd: dir, env: env) }
    func commit(_ dir: URL, _ file: String, _ content: String, _ msg: String) async throws {
        try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try await sh(dir, ["add", "-A"]); try await sh(dir, ["commit", "-q", "-m", msg])
    }
    func upstreamCommit(_ file: String, _ msg: String) async throws {
        try await commit(upstreamWork, file, "\(msg)\n", msg); try await sh(upstreamWork, ["push", "-q", "origin", "main"])
    }
    func sha(_ dir: URL, _ ref: String) async throws -> String { try await sh(dir, ["rev-parse", ref]).trimmingCharacters(in: .whitespacesAndNewlines) }
    func originMain() async throws -> String { try await sha(originBare, "refs/heads/main") }

    // MARK: configure
    func testConfigureForkAddsUpstreamTracksItAndPushesToOrigin() async throws {
        let up = await repo.remoteURL("upstream")
        XCTAssertEqual(up, upstreamBare.path)
        let remote = try await sh(local, ["config", "branch.main.remote"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let push = try await sh(local, ["config", "branch.main.pushRemote"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remote, "upstream"); XCTAssertEqual(push, "origin")
        _ = try await repo.configureFork(upstreamURL: upstreamBare.path)           // idempotent
        do { _ = try await repo.configureFork(upstreamURL: "https://example.com/other.git"); XCTFail("must not repoint") }
        catch ForkError.upstreamConflict(let existing) { XCTAssertEqual(existing, upstreamBare.path) }
    }

    // MARK: sync
    func testUpToDateIsANoOp() async throws {
        let p = try await repo.forkSyncPreview()
        XCTAssertEqual(p.kind, .upToDate)
        let r = try await repo.syncFork()
        XCTAssertEqual(r.before, r.after); XCTAssertFalse(r.pushed); XCTAssertNil(r.backupRef)
    }

    func testFastForwardUpdatesLocalAndPushesToOrigin() async throws {
        try await upstreamCommit("u1.txt", "u1"); try await upstreamCommit("u2.txt", "u2")
        let p = try await repo.forkSyncPreview()
        XCTAssertEqual(p.kind, .fastForward); XCTAssertEqual(p.behind, 2); XCTAssertEqual(p.ahead, 0)
        let r = try await repo.syncFork()
        XCTAssertTrue(r.pushed); XCTAssertNil(r.backupRef, "a plain fast-forward loses nothing")
        let upstreamTip = try await sha(upstreamBare, "refs/heads/main")
        let originTip = try await originMain()
        XCTAssertEqual(r.after, upstreamTip); XCTAssertEqual(originTip, upstreamTip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("u2.txt").path))
    }

    func testFastForwardWhileAnotherBranchIsCheckedOutDoesNotSwitch() async throws {
        try await sh(local, ["switch", "-q", "-c", "feature"])
        try await upstreamCommit("u1.txt", "u1")
        let r = try await repo.syncFork()
        let upstreamTip = try await sha(upstreamBare, "refs/heads/main")
        let localMain = try await sha(local, "refs/heads/main")
        let cur = try await sh(local, ["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(localMain, upstreamTip); XCTAssertEqual(cur, "feature"); XCTAssertTrue(r.pushed)
    }

    func testDivergedRefusesFastForwardAndChangesNothing() async throws {
        try await commit(local, "mine.txt", "mine\n", "mine"); try await upstreamCommit("u1.txt", "u1")
        let before = try await sha(local, "HEAD")
        do { _ = try await repo.syncFork(); XCTFail("must not fast-forward") }
        catch ForkError.notFastForward(let a, let b) { XCTAssertEqual(a, 1); XCTAssertEqual(b, 1) }
        let after = try await sha(local, "HEAD")
        let origin = try await originMain()
        let backups = try await repo.backupRefs()
        XCTAssertEqual(before, after); XCTAssertNotEqual(origin, after); XCTAssertTrue(backups.isEmpty)
    }

    func testRebaseKeepsLocalCommitsOnTopForceWithLeaseAndBacksUp() async throws {
        try await commit(local, "mine.txt", "mine\n", "mine"); try await sh(local, ["push", "-q", "origin", "main"])
        try await upstreamCommit("u1.txt", "u1")
        let old = try await sha(local, "HEAD")
        let r = try await repo.syncFork(strategy: .rebase)
        XCTAssertTrue(r.pushed)
        let upstreamTip = try await sha(upstreamBare, "refs/heads/main")
        let parent = try await sha(local, "HEAD~1")
        let originTip = try await originMain()
        XCTAssertEqual(parent, upstreamTip, "local commit must sit on top of upstream")
        XCTAssertEqual(originTip, r.after)
        let backup = try XCTUnwrap(r.backupRef)
        let backupSha = try await sha(local, backup)
        XCTAssertEqual(backupSha, old)
    }

    func testMergeCreatesMergeCommitAndPushesWithoutForce() async throws {
        try await commit(local, "mine.txt", "mine\n", "mine"); try await upstreamCommit("u1.txt", "u1")
        let r = try await repo.syncFork(strategy: .merge)
        XCTAssertTrue(r.pushed)
        let parents = try await sh(local, ["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ")
        XCTAssertEqual(parents.count, 3, "merge commit has two parents")
        let originTip = try await originMain()
        XCTAssertEqual(originTip, r.after)
        XCTAssertNotNil(r.backupRef)
    }

    func testResetToUpstreamDropsLocalCommitsButKeepsThemInABackupRef() async throws {
        try await commit(local, "mine.txt", "mine\n", "mine"); try await sh(local, ["push", "-q", "origin", "main"])
        try await upstreamCommit("u1.txt", "u1")
        let mine = try await sha(local, "HEAD")
        let r = try await repo.syncFork(strategy: .resetToUpstream)
        let upstreamTip = try await sha(upstreamBare, "refs/heads/main")
        let originTip = try await originMain()
        XCTAssertEqual(r.after, upstreamTip); XCTAssertEqual(originTip, upstreamTip); XCTAssertTrue(r.pushed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("mine.txt").path))
        // Undo-equality: restoring from the backup ref brings back exactly the old tip and its tree.
        let backup = try XCTUnwrap(r.backupRef)
        try await sh(local, ["reset", "-q", "--hard", backup])
        let restored = try await sha(local, "HEAD")
        XCTAssertEqual(restored, mine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("mine.txt").path))
    }

    func testResetRefusesToDiscardUncommittedChanges() async throws {
        try await upstreamCommit("u1.txt", "u1")
        try "dirty".write(to: local.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        do { _ = try await repo.syncFork(strategy: .resetToUpstream); XCTFail("must refuse") } catch ForkError.dirtyWorkingTree {}
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("base.txt")), "dirty")
        let backups = try await repo.backupRefs()
        XCTAssertTrue(backups.isEmpty, "no backup for an operation that did not run")
    }

    func testStaleLeaseBlocksTheForcePush() async throws {
        try await commit(local, "mine.txt", "mine\n", "mine"); try await sh(local, ["push", "-q", "origin", "main"])
        try await upstreamCommit("u1.txt", "u1")
        let stale = try await sha(local, "HEAD~1")        // not what origin really has
        let originBefore = try await originMain()
        do { _ = try await repo.syncFork(strategy: .rebase, expectedOrigin: stale); XCTFail("stale lease must be rejected") } catch is ShellError {}
        let originAfter = try await originMain()
        XCTAssertEqual(originBefore, originAfter, "origin must be untouched")
    }

    func testRebaseNeedsTheDefaultBranchCheckedOut() async throws {
        try await sh(local, ["switch", "-q", "-c", "feature"]); try await upstreamCommit("u1.txt", "u1")
        do { _ = try await repo.syncFork(strategy: .rebase); XCTFail() } catch ForkError.defaultBranchNotCheckedOut(let b) { XCTAssertEqual(b, "main") }
    }

    // MARK: provider side
    func testWaitUntilReadyPollsThenSucceeds() async throws {
        let n = Counter()
        try await Fork.waitUntilReady("x/y", timeout: 5, interval: 0.01) { await n.bump() >= 3 }
        let count = await n.value
        XCTAssertEqual(count, 3)
    }

    func testWaitUntilReadyTimesOut() async throws {
        do { try await Fork.waitUntilReady("x/y", timeout: 0.05, interval: 0.01) { false }; XCTFail() } catch ForkError.timedOut(let w) { XCTAssertEqual(w, "x/y") }
    }

    func testForkRequestShapes() throws {
        let gh = GitHubProvider(token: "t").forkRequest(repo: "o/r", options: ForkOptions(owner: "acme", name: "r2", defaultBranchOnly: true))
        XCTAssertEqual(gh.url?.absoluteString, "https://api.github.com/repos/o/r/forks"); XCTAssertEqual(gh.httpMethod, "POST")
        let b = JSONValue.parse(String(decoding: gh.httpBody ?? Data(), as: UTF8.self))
        XCTAssertEqual(b?["organization"]?.string, "acme"); XCTAssertEqual(b?["name"]?.string, "r2"); XCTAssertEqual(b?["default_branch_only"]?.bool, true)
        let plain = GitHubProvider(token: "t").forkRequest(repo: "o/r", options: ForkOptions())
        XCTAssertEqual(JSONValue.parse(String(decoding: plain.httpBody ?? Data(), as: UTF8.self)), .object([:]))

        let gl = GitLabProvider(token: "t").forkRequest(repo: "grp/sub/r", options: ForkOptions(owner: "me", name: "r2"), branches: "main")
        XCTAssertEqual(gl.url?.absoluteString, "https://gitlab.com/api/v4/projects/grp%2Fsub%2Fr/fork")
        let g = JSONValue.parse(String(decoding: gl.httpBody ?? Data(), as: UTF8.self))
        XCTAssertEqual(g?["namespace_path"]?.string, "me"); XCTAssertEqual(g?["branches"]?.string, "main"); XCTAssertEqual(g?["path"]?.string, "r2")
    }
}

actor Counter { var value = 0; func bump() -> Int { value += 1; return value } }
