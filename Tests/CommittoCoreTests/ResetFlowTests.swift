import XCTest
@testable import CommittoCore

final class ResetFlowTests: XCTestCase {
    var root: URL!, dir: URL!
    var saved: [String: String?] = [:]
    var repo: GitRepository { GitRepository(url: dir) }
    var env: [String: String] {
        ["HOME": root.path, "GIT_CONFIG_GLOBAL": root.appendingPathComponent("gitconfig").path, "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"]
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("committo-reset-\(UUID().uuidString)")
        dir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (k, v) in env { saved[k] = getenv(k).map { String(cString: $0) }; setenv(k, v, 1) }
        try await g(["init", "-q", "-b", "main"])
    }
    override func tearDown() async throws {
        for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult func g(_ a: [String], in d: URL? = nil) async throws -> String { try await Shell.check("git", a, cwd: d ?? dir, env: env) }
    func write(_ f: String, _ c: String) throws { try c.write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
    func commit(_ f: String, _ c: String, _ m: String) async throws { try write(f, c); try await g(["add", "-A"]); try await g(["commit", "-q", "-m", m]) }
    func rev(_ r: String, in d: URL? = nil) async throws -> String { try await g(["rev-parse", r], in: d).trimmingCharacters(in: .whitespacesAndNewlines) }
    func history(_ n: Int = 4) async throws -> [String] {
        for i in 1...n { try await commit("f\(i).txt", "v\(i)\n", "c\(i)") }
        return try await g(["log", "--reverse", "--format=%H"]).split(separator: "\n").map(String.init)
    }

    /// Everything a user could notice: branch tip, index tree, staged and unstaged tracked diffs, untracked files.
    func fingerprint() async throws -> String {
        [try await rev("HEAD"), try await g(["write-tree"]), try await g(["diff", "--cached"]), try await g(["diff"]),
         try await g(["ls-files", "--others", "--exclude-standard"]), try await g(["branch", "--show-current"])].joined(separator: "\u{1}")
    }

    // MARK: preview
    func testPreviewNamesTheLossAndCountsPublishedCommits() async throws {
        let h = try await history(4)
        try write("f1.txt", "dirty\n"); try write("f2.txt", "dirty\n")
        let p = try await repo.resetPreview(to: h[1], mode: .hard)
        XCTAssertEqual(p.leaving.map(\.subject), ["c4", "c3"]); XCTAssertTrue(p.gaining.isEmpty)
        XCTAssertEqual(p.changesLost, 2); XCTAssertEqual(p.buttonTitle, "Reset hard, 2 changes lost")
        let soft = try await repo.resetPreview(to: h[1], mode: .soft)
        XCTAssertEqual(soft.changesLost, 0); XCTAssertEqual(soft.buttonTitle, "Reset soft")
        let fwd = try await repo.resetPreview(to: h[3], mode: .mixed)
        XCTAssertTrue(fwd.leaving.isEmpty); XCTAssertTrue(fwd.gaining.isEmpty)
    }

    func testPreviewCountsCommitsAlreadyOnUpstream() async throws {
        let bare = root.appendingPathComponent("o.git"); try await g(["init", "-q", "--bare", "-b", "main", bare.path], in: root)
        let h = try await history(3)
        try await g(["remote", "add", "origin", bare.path]); try await g(["push", "-q", "-u", "origin", "main"])
        try await commit("local.txt", "l\n", "unpublished")
        let p = try await repo.resetPreview(to: h[0], mode: .mixed)
        XCTAssertEqual(p.leaving.count, 3); XCTAssertEqual(p.publishedLeaving, 2, "c2,c3 are on origin; 'unpublished' is not")
    }

    // MARK: reset modes
    func testModesMoveTheRightThings() async throws {
        let h = try await history(3)             // h[2] is HEAD; resetting to h[1] drops f3.txt's commit
        func fresh() async throws { try await g(["reset", "-q", "--hard", h[2]]); try await g(["clean", "-qfd"]) }
        func has(_ f: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) }

        try await fresh(); try await repo.resetSafely(to: h[1], mode: .soft)
        var head = try await rev("HEAD"); var staged = try await g(["diff", "--cached", "--name-only"]); var work = try await g(["diff", "--name-only"])
        XCTAssertEqual(head, h[1]); XCTAssertEqual(staged, "f3.txt\n", "soft keeps the dropped commit's changes staged"); XCTAssertEqual(work, ""); XCTAssertTrue(has("f3.txt"))

        try await fresh(); try await repo.resetSafely(to: h[1], mode: .mixed)
        head = try await rev("HEAD"); staged = try await g(["diff", "--cached", "--name-only"]); var others = try await g(["ls-files", "--others", "--exclude-standard"])
        XCTAssertEqual(head, h[1]); XCTAssertEqual(staged, ""); XCTAssertEqual(others, "f3.txt\n", "mixed unstages but keeps the file"); XCTAssertTrue(has("f3.txt"))

        try await fresh(); try await repo.resetSafely(to: h[1], mode: .hard)
        head = try await rev("HEAD"); staged = try await g(["status", "--porcelain"])
        XCTAssertEqual(head, h[1]); XCTAssertEqual(staged, ""); XCTAssertFalse(has("f3.txt"))

        try await fresh(); try write("new.txt", "n\n"); try await g(["add", "new.txt"])
        try await repo.resetSafely(to: h[1], mode: .keep)
        head = try await rev("HEAD"); staged = try await g(["diff", "--cached", "--name-only"]); others = try await g(["ls-files", "--others", "--exclude-standard"])
        work = try await g(["diff", "--name-only"])
        XCTAssertEqual(head, h[1]); XCTAssertTrue(has("new.txt"), "keep retains local changes"); XCTAssertFalse(has("f3.txt"))
        _ = (others, work)
    }

    func testKeepRefusesWhenChangesConflictAndLeavesNoTrace() async throws {
        let h = try await history(3)
        try write("f3.txt", "local edit\n")                   // f3 differs between HEAD and target h[1]
        let before = try await fingerprint()
        do { try await repo.resetSafely(to: h[1], mode: .keep); XCTFail("keep must refuse") } catch is ShellError {}
        let after = try await fingerprint(); let backups = try await repo.listBackups()
        XCTAssertEqual(before, after); XCTAssertTrue(backups.isEmpty, "a failed operation leaves no backup")
    }

    func testHardResetThenRestoreIsExactlyTheStateBefore() async throws {
        let h = try await history(4)
        try write("f4.txt", "staged edit\n"); try await g(["add", "f4.txt"])
        try write("f4.txt", "staged edit\nplus unstaged\n"); try write("f1.txt", "unstaged only\n"); try write("untracked.txt", "u\n")
        let before = try await fingerprint()
        let snap = try await repo.resetSafely(to: h[0], mode: .hard)
        let mid = try await fingerprint(); XCTAssertNotEqual(before, mid)
        try await repo.restore(snap)
        let after = try await fingerprint(); XCTAssertEqual(before, after)
    }

    func testRestoreIsItselfUndoableAndRefusesOnTheWrongBranch() async throws {
        let h = try await history(3)
        let snap = try await repo.resetSafely(to: h[0], mode: .hard)
        let undo = try await repo.restore(snap)
        let restored = try await rev("HEAD"); XCTAssertEqual(restored, h[2])
        try await repo.restore(undo)                                 // undo the undo: back to the reset state
        let again = try await rev("HEAD"); XCTAssertEqual(again, h[0], "restoring the restore's own snapshot returns to the pre-restore state")
        try await g(["switch", "-q", "-c", "other"])
        do { try await repo.restore(snap); XCTFail() } catch ResetFlowError.wrongBranch(let e, let a) { XCTAssertEqual(e, "main"); XCTAssertEqual(a, "other") }
    }

    func testRandomResetsAlwaysRestoreExactly() async throws {
        var rng = SeededRNG(seed: 42)
        let h = try await history(5)
        for round in 0..<25 {
            try await g(["reset", "-q", "--hard", h[4]]); try await g(["clean", "-qfd"])
            // random dirty state
            if Bool.random(using: &rng) { try write("f\(Int.random(in: 1...5, using: &rng)).txt", "edit \(round)\n") }
            if Bool.random(using: &rng) { let f = "f\(Int.random(in: 1...5, using: &rng)).txt"; try write(f, "staged \(round)\n"); try await g(["add", f]) }
            if Bool.random(using: &rng) { try write("untracked-\(round).txt", "u\n") }
            let target = h.randomElement(using: &rng)!, mode = ResetMode.allCases.randomElement(using: &rng)!
            let before = try await fingerprint()
            do {
                let snap = try await repo.resetSafely(to: target, mode: mode)
                try await repo.restore(snap)
                let after = try await fingerprint()
                XCTAssertEqual(before, after, "round \(round) \(mode) -> \(target.prefix(7))")
            } catch is ShellError {
                let after = try await fingerprint()
                XCTAssertEqual(before, after, "round \(round) \(mode): refused reset must change nothing")
            }
        }
    }

    // MARK: force push
    func originAndClone() async throws -> (bare: URL, other: URL) {
        let bare = root.appendingPathComponent("o.git"); try await g(["init", "-q", "--bare", "-b", "main", bare.path], in: root)
        try await commit("a.txt", "a\n", "a"); try await commit("b.txt", "b\n", "b")
        try await g(["remote", "add", "origin", bare.path]); try await g(["push", "-q", "-u", "origin", "main"])
        let other = root.appendingPathComponent("other"); try await g(["clone", "-q", bare.path, other.path], in: root)
        return (bare, other)
    }

    func testLeasedForcePushOverwritesOnlyWhatYouReviewedAndKeepsTheOldTip() async throws {
        let (bare, _) = try await originAndClone()
        let oldRemote = try await rev("origin/main")
        try await g(["reset", "-q", "--hard", "HEAD~1"]); try await commit("b2.txt", "b2\n", "b2")
        let plan = try await repo.forcePushPlan()
        XCTAssertEqual(plan.overwrites.map(\.subject), ["b"]); XCTAssertEqual(plan.adds, 1); XCTAssertEqual(plan.expectedRemote, oldRemote)
        try await repo.forcePush(plan)
        let remote = try await rev("refs/heads/main", in: bare); let local = try await rev("HEAD")
        XCTAssertEqual(remote, local)
        let backups = try await repo.listBackups()
        XCTAssertTrue(backups.contains { $0.sha == oldRemote && $0.label.hasPrefix("remote-origin-main") }, "overwritten remote tip must stay recoverable")
    }

    func testForcePushIsBlockedWhenTheRemoteMovedAfterYouLookedAndNothingIsOverwritten() async throws {
        let (bare, other) = try await originAndClone()
        try await g(["reset", "-q", "--hard", "HEAD~1"]); try await commit("b2.txt", "b2\n", "b2")
        let plan = try await repo.forcePushPlan()
        // A teammate pushes while the plan is on screen.
        try "t\n".write(to: other.appendingPathComponent("team.txt"), atomically: true, encoding: .utf8)
        try await g(["add", "-A"], in: other); try await g(["commit", "-q", "-m", "teammate"], in: other); try await g(["push", "-q", "origin", "main"], in: other)
        let theirs = try await rev("refs/heads/main", in: bare)
        do { try await repo.forcePush(plan); XCTFail("lease must block") } catch ResetFlowError.remoteMoved(let b) { XCTAssertEqual(b, "main") }
        let after = try await rev("refs/heads/main", in: bare); XCTAssertEqual(theirs, after)
    }

    func testPlainForceIsRefusedByDefaultAndOnProtectedBranches() async throws {
        let (bare, _) = try await originAndClone()
        try await g(["reset", "-q", "--hard", "HEAD~1"]); try await commit("b2.txt", "b2\n", "b2")
        let plan = try await repo.forcePushPlan(); let remoteBefore = try await rev("refs/heads/main", in: bare)
        do { try await repo.forcePush(plan, mode: .plain(allowPlain: false, branchIsProtected: false)); XCTFail() } catch ResetFlowError.plainForceRefused {}
        do { try await repo.forcePush(plan, mode: .plain(allowPlain: true, branchIsProtected: true)); XCTFail() } catch ResetFlowError.plainForceRefused {}
        let remoteAfter = try await rev("refs/heads/main", in: bare); XCTAssertEqual(remoteBefore, remoteAfter)
        try await repo.forcePush(plan, mode: .plain(allowPlain: true, branchIsProtected: false))
        let pushed = try await rev("refs/heads/main", in: bare); let local = try await rev("HEAD"); XCTAssertEqual(pushed, local)
    }

    func testPlanErrorsAreTyped() async throws {
        _ = try await originAndClone()
        do { _ = try await repo.forcePushPlan(); XCTFail() } catch ResetFlowError.nothingToPush {}
        try await g(["switch", "-q", "-c", "unpublished"])
        do { _ = try await repo.forcePushPlan(); XCTFail() } catch ResetFlowError.noRemoteBranch(let b) { XCTAssertEqual(b, "unpublished") }
    }

    // MARK: switching
    func twoBranches() async throws {
        try await commit("shared.txt", "one\n", "one"); try await g(["switch", "-q", "-c", "other"])
        try await commit("shared.txt", "two\n", "two"); try await g(["switch", "-q", "main"])
    }

    func testCarryWorksWhenNothingConflictsAndAsksForADecisionWhenItDoes() async throws {
        try await twoBranches()
        try write("mine.txt", "m\n")                                  // untracked: carries fine
        try await repo.switchBranch("other", policy: .carry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mine.txt").path))
        try await g(["switch", "-q", "main"]); try write("shared.txt", "my edit\n")
        let before = try await fingerprint()
        do { try await repo.switchBranch("other", policy: .carry); XCTFail() } catch ResetFlowError.needsDecision {}
        let after = try await fingerprint(); XCTAssertEqual(before, after)
    }

    func testStashPolicyKeepsEverythingIncludingUntracked() async throws {
        try await twoBranches(); try write("shared.txt", "my edit\n"); try write("new.txt", "n\n")
        try await repo.switchBranch("other", policy: .stash)
        let cur = try await g(["branch", "--show-current"]); let status = try await g(["status", "--porcelain"])
        XCTAssertEqual(cur.trimmingCharacters(in: .whitespacesAndNewlines), "other"); XCTAssertEqual(status, "")
        let stash = try await g(["stash", "list"]); XCTAssertTrue(stash.contains("before switching from main to other"))
        try await g(["switch", "-q", "main"]); try await g(["stash", "pop", "-q", "--index"]); XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.txt").path))
    }

    func testDiscardPolicyCanBeUndoneFromItsSnapshot() async throws {
        try await twoBranches(); try write("shared.txt", "precious\n")
        try await g(["add", "shared.txt"]); try write("shared.txt", "precious\nmore\n")
        let before = try await fingerprint()
        let maybeSnap = try await repo.switchBranch("other", policy: .discard)
        let snap = try XCTUnwrap(maybeSnap)
        let nowBranch = try await g(["branch", "--show-current"]); XCTAssertEqual(nowBranch.trimmingCharacters(in: .whitespacesAndNewlines), "other")
        try await g(["switch", "-q", "main"])
        try await repo.restore(snap)
        let after = try await fingerprint(); XCTAssertEqual(before, after)
    }

    func testDetachedHeadCanBeSavedToABranch() async throws {
        let h = try await history(2)
        try await g(["switch", "-q", "--detach", h[0]])
        let detached = await repo.isDetached; XCTAssertTrue(detached)
        try await repo.saveDetachedHead(as: "rescued")
        let cur = try await g(["branch", "--show-current"]); let tip = try await rev("rescued")
        XCTAssertEqual(cur.trimmingCharacters(in: .whitespacesAndNewlines), "rescued"); XCTAssertEqual(tip, h[0])
    }

    // MARK: backups
    func testBackupsAreListedAndPrunedAfterThirtyDays() async throws {
        let h = try await history(3)
        try await repo.resetSafely(to: h[0], mode: .hard)
        let list = try await repo.listBackups()
        XCTAssertEqual(list.count, 1); XCTAssertEqual(list[0].sha, h[2]); XCTAssertTrue(list[0].label.hasPrefix("main-reset-hard"), list[0].label)
        XCTAssertLessThan(abs(list[0].date.timeIntervalSinceNow), 60)
        var n = try await repo.pruneBackups(now: Date().addingTimeInterval(29 * 86_400)); XCTAssertEqual(n, 0)
        n = try await repo.pruneBackups(now: Date().addingTimeInterval(31 * 86_400)); XCTAssertEqual(n, 1)
        let after = try await repo.listBackups(); XCTAssertTrue(after.isEmpty)
    }
}
