import XCTest
@testable import CommittoCore

final class InteractiveRebaseTests: XCTestCase {
    var root: URL!, repoDir: URL!
    var saved: [String: String?] = [:]
    var repo: GitRepository { GitRepository(url: repoDir) }
    var env: [String: String] {
        ["HOME": root.path, "GIT_CONFIG_GLOBAL": root.appendingPathComponent("gitconfig").path, "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"]
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("committo-rebase-\(UUID().uuidString)")
        repoDir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        for (k, v) in env { saved[k] = getenv(k).map { String(cString: $0) }; setenv(k, v, 1) }
        try await g(["init", "-q", "-b", "main"])
        try await commit("base.txt", "base\n", "base")
    }
    override func tearDown() async throws {
        for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult func g(_ a: [String]) async throws -> String { try await Shell.check("git", a, cwd: repoDir, env: env) }
    func commit(_ file: String, _ content: String, _ msg: String) async throws {
        try content.write(to: repoDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try await g(["add", "-A"]); try await g(["commit", "-q", "-m", msg])
    }
    func rev(_ r: String) async throws -> String { try await g(["rev-parse", r]).trimmingCharacters(in: .whitespacesAndNewlines) }
    func subjects() async throws -> [String] { try await g(["log", "--reverse", "--format=%s", "base..HEAD"]).split(separator: "\n").map(String.init) }
    func tree() async throws -> String { try await rev("HEAD^{tree}") }
    func exists(_ f: String) -> Bool { FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(f).path) }

    /// Three independent commits A, B, C on top of a `base` tag.
    func abc() async throws -> [RebaseStep] {
        try await g(["tag", "base"])
        for n in ["A", "B", "C"] { try await commit("\(n).txt", "\(n)\n", n) }
        return try await repo.rebasePlan(onto: "base")
    }
    func completed(_ o: RebaseOutcome, file: StaticString = #filePath, line: UInt = #line) -> (head: String, backup: String?, force: Bool, expected: String?)? {
        if case .completed(let h, let b, let f, let e) = o { return (h, b, f, e) }
        XCTFail("expected completion, got \(o)", file: file, line: line); return nil
    }

    func testPlanListsCommitsOldestFirstAsPicks() async throws {
        let plan = try await abc()
        XCTAssertEqual(plan.map(\.subject), ["A", "B", "C"]); XCTAssertTrue(plan.allSatisfy { $0.action == .pick })
    }

    func testReorderKeepsTreeAndChangesOrder() async throws {
        var plan = try await abc(); let before = try await tree()
        plan = [plan[2], plan[0], plan[1]]
        let out = try await repo.interactiveRebase(onto: "base", plan: plan)
        _ = try XCTUnwrap(completed(out))
        let subs = try await subjects(); let after = try await tree()
        XCTAssertEqual(subs, ["C", "A", "B"]); XCTAssertEqual(before, after, "independent commits: same final tree")
    }

    func testDropRemovesTheCommitsChanges() async throws {
        var plan = try await abc(); plan[1].action = .drop
        _ = try await repo.interactiveRebase(onto: "base", plan: plan)
        let subs = try await subjects()
        XCTAssertEqual(subs, ["A", "C"]); XCTAssertFalse(exists("B.txt")); XCTAssertTrue(exists("C.txt"))
    }

    func testFixupAndSquashFoldIntoPrevious() async throws {
        var plan = try await abc(); let before = try await tree()
        plan[1].action = .squash; plan[2].action = .fixup
        _ = try await repo.interactiveRebase(onto: "base", plan: plan)
        let subs = try await subjects(); let after = try await tree()
        XCTAssertEqual(subs, ["A"]); XCTAssertEqual(before, after)
        let body = try await g(["log", "-1", "--format=%B"])
        XCTAssertTrue(body.contains("B"), "squash keeps the squashed message"); XCTAssertFalse(body.contains("\nC"), "fixup discards its message")
    }

    func testRewordChangesOnlyTheMessage() async throws {
        var plan = try await abc(); let before = try await tree()
        plan[1].action = .reword; plan[1].message = "B, but better"
        _ = try await repo.interactiveRebase(onto: "base", plan: plan)
        let subs = try await subjects(); let after = try await tree()
        XCTAssertEqual(subs, ["A", "B, but better", "C"]); XCTAssertEqual(before, after)
    }

    func testEditStopsThenContinueFinishesWithTheAmendment() async throws {
        var plan = try await abc(); plan[1].action = .edit
        let out = try await repo.interactiveRebase(onto: "base", plan: plan)
        guard case .stopped(let st) = out else { return XCTFail("expected stop at edit") }
        XCTAssertTrue(st.inProgress); XCTAssertTrue(st.conflictedFiles.isEmpty)
        try await commit("extra.txt", "x\n", "extra")        // user work during the stop
        let doneOut = try await repo.continueRebase()
        _ = try XCTUnwrap(completed(doneOut))
        let subs = try await subjects(); let state = await repo.rebaseState()
        XCTAssertEqual(subs, ["A", "B", "extra", "C"]); XCTAssertFalse(state.inProgress)
    }

    func testConflictStopsAndAbortRestoresEverythingExactly() async throws {
        try await g(["tag", "base"])
        try await commit("f.txt", "1\n", "one"); try await commit("f.txt", "2\n", "two")
        let plan = try await repo.rebasePlan(onto: "base")
        let head = try await rev("HEAD"); let tr = try await tree()
        let out = try await repo.interactiveRebase(onto: "base", plan: [plan[1], plan[0]])      // reordering dependent edits conflicts
        guard case .stopped(let st) = out else { return XCTFail("expected conflict stop") }
        XCTAssertEqual(st.conflictedFiles, ["f.txt"])
        try await repo.abortRebase()
        let h = try await rev("HEAD"); let t = try await tree(); let s = await repo.rebaseState(); let status = try await g(["status", "--porcelain"])
        XCTAssertEqual(h, head); XCTAssertEqual(t, tr); XCTAssertFalse(s.inProgress); XCTAssertEqual(status, "")
        let backups = try await repo.backupRefs()
        XCTAssertEqual(backups.count, 1)
        let b = try await rev(backups[0]); XCTAssertEqual(b, head)
    }

    func testSkipDropsTheConflictingCommitAndFinishes() async throws {
        try await g(["tag", "base"])
        try await commit("f.txt", "1\n", "one"); try await commit("f.txt", "2\n", "two")
        let plan = try await repo.rebasePlan(onto: "base")
        _ = try await repo.interactiveRebase(onto: "base", plan: [plan[1], plan[0]])
        let doneOut = try await repo.skipRebase()
        _ = try XCTUnwrap(completed(doneOut))
        let subs = try await subjects(); XCTAssertEqual(subs, ["one"], "plan was [two, one]; skipping the conflicting `two` leaves `one`")
    }

    func testBadPlansAreRejectedBeforeAnythingIsTouched() async throws {
        let plan = try await abc(); let head = try await rev("HEAD")
        func rejects(_ p: [RebaseStep], _ check: (RebaseError) -> Bool, _ what: String) async {
            do { _ = try await repo.interactiveRebase(onto: "base", plan: p); XCTFail("accepted: \(what)") }
            catch let e as RebaseError { XCTAssertTrue(check(e), "\(what): \(e)") } catch { XCTFail("\(what): \(error)") }
        }
        await rejects(Array(plan.prefix(2)), { if case .planMismatch(let m, _, _) = $0 { return m.count == 1 }; return false }, "missing commit")
        await rejects(plan + [plan[0]], { if case .planMismatch(_, _, let d) = $0 { return d.count == 1 }; return false }, "duplicate")
        await rejects([RebaseStep(hash: String(repeating: "a", count: 40))] + plan, { if case .planMismatch(_, let u, _) = $0 { return u.count == 1 }; return false }, "unknown")
        var sq = plan; sq[0].action = .squash
        await rejects(sq, { $0 == .firstStepCannotSquash }, "first squash")
        var dropFirst = plan; dropFirst[0].action = .drop; dropFirst[1].action = .fixup
        await rejects(dropFirst, { $0 == .firstStepCannotSquash }, "fixup after dropped first")
        var rw = plan; rw[0].action = .reword
        await rejects(rw, { if case .messageNeeded = $0 { return true }; return false }, "reword without message")
        await rejects([], { $0 == .emptyPlan }, "empty")
        let after = try await rev("HEAD"); let backups = try await repo.backupRefs(); let s = await repo.rebaseState()
        XCTAssertEqual(head, after); XCTAssertTrue(backups.isEmpty); XCTAssertFalse(s.inProgress)
    }

    func testMergesInRangeAreRefused() async throws {
        try await g(["tag", "base"])
        try await g(["switch", "-q", "-c", "side"]); try await commit("s.txt", "s\n", "side")
        try await g(["switch", "-q", "main"]); try await commit("m.txt", "m\n", "main")
        try await g(["merge", "-q", "--no-ff", "-m", "merge", "side"])
        do { _ = try await repo.rebasePlan(onto: "base"); XCTFail() } catch RebaseError.containsMerges(let n) { XCTAssertEqual(n, 1) }
    }

    func testDirtyWorkingTreeIsPreservedByAutostash() async throws {
        var plan = try await abc(); plan[1].action = .drop
        try "local edit\n".write(to: repoDir.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await repo.interactiveRebase(onto: "base", plan: plan)
        XCTAssertEqual(try String(contentsOf: repoDir.appendingPathComponent("base.txt")), "local edit\n")
    }

    func testCompletedRebaseLeavesNoScratchFiles() async throws {
        let plan = try await abc()
        _ = try await repo.interactiveRebase(onto: "base", plan: [plan[1], plan[0], plan[2]])
        let work = try await repo.gitPath("committo-rebase")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testBackupRefRestoresTheOriginalBranchAfterACompletedRewrite() async throws {
        var plan = try await abc(); let head = try await rev("HEAD")
        plan[1].action = .drop
        let oout = try await repo.interactiveRebase(onto: "base", plan: plan)
        let o = try XCTUnwrap(completed(oout))
        let backup = try XCTUnwrap(o.backup)
        try await g(["reset", "-q", "--hard", backup])
        let restored = try await rev("HEAD"); XCTAssertEqual(restored, head); XCTAssertTrue(exists("B.txt"))
    }

    // MARK: pushed branches
    func testRewritingPublishedCommitsNeedsALeasedForcePush() async throws {
        let bare = root.appendingPathComponent("origin.git")
        try await Shell.check("git", ["init", "-q", "--bare", "-b", "main", bare.path], env: env)
        try await g(["remote", "add", "origin", bare.path])
        var plan = try await abc()
        try await g(["push", "-q", "-u", "origin", "main"])
        plan[1].action = .reword; plan[1].message = "B2"
        let oout = try await repo.interactiveRebase(onto: "base", plan: plan)
        let o = try XCTUnwrap(completed(oout))
        XCTAssertTrue(o.force); XCTAssertNotNil(o.expected)
        do { try await g(["push", "origin", "main"]); XCTFail("plain push must be rejected") } catch is ShellError {}
        try await repo.pushRewritten(expectedRemote: o.expected)
        let remote = try await Shell.check("git", ["rev-parse", "main"], cwd: bare, env: env).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remote, o.head)
    }

    func testStaleLeaseOnRewrittenPushIsRejected() async throws {
        let bare = root.appendingPathComponent("origin.git")
        try await Shell.check("git", ["init", "-q", "--bare", "-b", "main", bare.path], env: env)
        try await g(["remote", "add", "origin", bare.path])
        var plan = try await abc(); try await g(["push", "-q", "-u", "origin", "main"])
        plan[2].action = .reword; plan[2].message = "C2"
        _ = try await repo.interactiveRebase(onto: "base", plan: plan)
        let before = try await Shell.check("git", ["rev-parse", "main"], cwd: bare, env: env)
        do { try await repo.pushRewritten(expectedRemote: try await rev("base")); XCTFail("stale lease") } catch is ShellError {}
        let after = try await Shell.check("git", ["rev-parse", "main"], cwd: bare, env: env)
        XCTAssertEqual(before, after)
    }

    func testUnpublishedRewriteDoesNotAskForForcePush() async throws {
        let bare = root.appendingPathComponent("origin.git")
        try await Shell.check("git", ["init", "-q", "--bare", "-b", "main", bare.path], env: env)
        try await g(["remote", "add", "origin", bare.path]); try await g(["push", "-q", "-u", "origin", "main"])
        var plan = try await abc()                       // A, B, C created after the push: not published
        plan[0].action = .reword; plan[0].message = "A2"
        let oout = try await repo.interactiveRebase(onto: "base", plan: plan)
        let o = try XCTUnwrap(completed(oout))
        XCTAssertFalse(o.force)
    }

    // MARK: pure helpers
    func testAutosquashMovesFixupsBehindTheirTargets() {
        let s = [RebaseStep(hash: "1", subject: "add login"), RebaseStep(hash: "2", subject: "add cart"),
                 RebaseStep(hash: "3", subject: "fixup! add login"), RebaseStep(hash: "4", subject: "squash! add cart"), RebaseStep(hash: "5", subject: "fixup! add login")]
        let r = InteractiveRebase.autosquash(s)
        XCTAssertEqual(r.map(\.hash), ["1", "3", "5", "2", "4"])
        XCTAssertEqual(r.map(\.action), [.pick, .fixup, .fixup, .pick, .squash])
        let orphan = InteractiveRebase.autosquash([RebaseStep(hash: "1", subject: "x"), RebaseStep(hash: "2", subject: "fixup! nothing")])
        XCTAssertEqual(orphan.map(\.hash), ["1", "2"]); XCTAssertEqual(orphan[1].action, .pick)
    }

    func testPreviewNamesRewrittenAndDroppedCommits() {
        let orig = ["a", "b", "c", "d"]
        func steps(_ h: [String], _ edit: (inout [RebaseStep]) -> Void = { _ in }) -> [RebaseStep] { var s = h.map { RebaseStep(hash: $0) }; edit(&s); return s }
        XCTAssertEqual(InteractiveRebase.preview(original: orig, plan: steps(orig)).rewritten, [])
        let swapped = InteractiveRebase.preview(original: orig, plan: steps(["a", "c", "b", "d"]))
        XCTAssertEqual(swapped.unchanged, ["a"]); XCTAssertEqual(swapped.rewritten, ["c", "b", "d"])
        let dropped = InteractiveRebase.preview(original: orig, plan: steps(orig) { $0[1].action = .drop })
        XCTAssertEqual(dropped.dropped, ["b"]); XCTAssertEqual(dropped.rewritten, ["c", "d"])
    }

    // MARK: randomized model check
    func testRandomPlansOverIndependentCommitsMatchTheModel() async throws {
        var rng = SeededRNG(seed: 20261016)
        try await g(["tag", "base"])
        let n = 5
        for i in 0..<n { try await commit("f\(i).txt", "\(i)\n", "c\(i)") }
        let tip = try await rev("HEAD"); let original = try await repo.rebasePlan(onto: "base")
        for round in 0..<20 {
            try await g(["reset", "-q", "--hard", tip])
            var plan = original.shuffled(using: &rng)
            for i in plan.indices { plan[i].action = [.pick, .pick, .drop, .squash, .fixup, .reword].randomElement(using: &rng)! }
            if let first = plan.firstIndex(where: { $0.action != .drop }), plan[first].action == .squash || plan[first].action == .fixup { plan[first].action = .pick }
            for i in plan.indices where plan[i].action == .reword { plan[i].message = "reworded-\(round)-\(i)" }
            let desc = plan.map { "\($0.subject):\($0.action.rawValue)" }.joined(separator: " ")

            // Model: groups led by a pick/reword; squash/fixup attach to the nearest earlier non-dropped step.
            var groups: [(subject: String, files: [String])] = []
            for s in plan where s.action != .drop {
                switch s.action {
                case .pick: groups.append((s.subject, ["f\(s.subject.dropFirst()).txt"]))
                case .reword: groups.append((s.message!, ["f\(s.subject.dropFirst()).txt"]))
                default: groups[groups.count - 1].files.append("f\(s.subject.dropFirst()).txt")
                }
            }
            let out = try await repo.interactiveRebase(onto: "base", plan: plan)
            guard case .completed = out else { return XCTFail("round \(round) did not complete: \(desc)") }
            // A reword on a squash/fixup head's *later* member overrides the group message; model that.
            var lastMessage: [Int: String] = [:]; var gi = -1
            for s in plan where s.action != .drop {
                if s.action == .pick || s.action == .reword { gi += 1 }
                if (s.action == .squash || s.action == .fixup), let m = s.message { lastMessage[gi] = m }
            }
            let subs = try await subjects()
            XCTAssertEqual(subs.count, groups.count, "round \(round): \(desc)")
            for (i, g) in groups.enumerated() where lastMessage[i] == nil && i < subs.count { XCTAssertEqual(subs[i], g.subject, "round \(round) group \(i): \(desc)") }
            let present = Set(groups.flatMap(\.files))
            for i in 0..<n { XCTAssertEqual(exists("f\(i).txt"), present.contains("f\(i).txt"), "round \(round) f\(i): \(desc)") }
        }
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
