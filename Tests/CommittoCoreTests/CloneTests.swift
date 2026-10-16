import XCTest
@testable import CommittoCore

/// Real git against local repositories in a temp dir with an isolated global config.
final class CloneTests: XCTestCase {
    var root: URL!
    var env: [String: String] {
        ["HOME": root.path, "GIT_CONFIG_GLOBAL": root.appendingPathComponent("gitconfig").path, "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"]
    }
    /// Submodules from local paths need the file transport enabled, exactly as a user would for local testing.
    var opts: CloneOptions { var o = CloneOptions(); o.gitConfig["protocol.file.allow"] = "always"; return o }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("committo-clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { if let root { try? FileManager.default.removeItem(at: root) } }

    @discardableResult
    func g(_ dir: URL, _ args: [String]) async throws -> String {
        try await Shell.check("git", ["-c", "protocol.file.allow=always"] + args, cwd: dir, env: env)
    }
    func makeRepo(_ name: String, files: [String: String] = ["a.txt": "a\n"]) async throws -> URL {
        let d = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try await g(d, ["init", "-q", "-b", "main"])
        for (f, c) in files {
            let u = d.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try c.write(to: u, atomically: true, encoding: .utf8)
        }
        try await g(d, ["add", "-A"]); try await g(d, ["commit", "-q", "-m", "init"])
        return d
    }
    func collect(_ s: AsyncThrowingStream<CloneEvent, Error>) async throws -> [CloneEvent] {
        var out: [CloneEvent] = []; for try await e in s { out.append(e) }; return out
    }
    func results(_ ev: [CloneEvent]) -> [SubmoduleResult] { ev.compactMap { if case .submodule(let r) = $0 { r } else { nil } } }

    func testPlainCloneWithBranchAndDepth() async throws {
        let src = try await makeRepo("src")
        try await g(src, ["checkout", "-q", "-b", "feature"])
        try "b\n".write(to: src.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await g(src, ["add", "-A"]); try await g(src, ["commit", "-q", "-m", "second"])
        var o = opts; o.branch = "feature"; o.depth = 1
        let dest = root.appendingPathComponent("dest")
        let ev = try await collect(Clone.run("file://" + src.path, into: dest, options: o))
        XCTAssertEqual(ev.last, .finished(failedSubmodules: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("b.txt").path))
        let count = try await g(dest, ["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(count, "1")
        let branch = try await g(dest, ["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "feature")
    }

    func testSubmodulesAreInitialisedAndReportedClean() async throws {
        let sub = try await makeRepo("sub", files: ["s.txt": "s\n"])
        let main = try await makeRepo("main")
        try await g(main, ["submodule", "add", "-q", "file://" + sub.path, "vendor/sub"]); try await g(main, ["commit", "-q", "-m", "add sub"])
        let dest = root.appendingPathComponent("dest")
        let ev = try await collect(Clone.run("file://" + main.path, into: dest, options: opts))
        XCTAssertEqual(results(ev).map(\.path), ["vendor/sub"])
        XCTAssertTrue(results(ev).allSatisfy(\.ok))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("vendor/sub/s.txt").path))
        let states = try await GitRepository(url: dest).submodules().map(\.state)
        XCTAssertEqual(states, [.clean])
    }

    func testSubmodulesOffLeavesThemUninitialised() async throws {
        let sub = try await makeRepo("sub")
        let main = try await makeRepo("main")
        try await g(main, ["submodule", "add", "-q", "file://" + sub.path, "sub"]); try await g(main, ["commit", "-q", "-m", "add sub"])
        var o = opts; o.submodules = false
        let dest = root.appendingPathComponent("dest")
        let ev = try await collect(Clone.run("file://" + main.path, into: dest, options: o))
        XCTAssertTrue(results(ev).isEmpty)
        let states = try await GitRepository(url: dest).submodules().map(\.state)
        XCTAssertEqual(states, [.uninitialised])
    }

    func testOneFailingSubmoduleDoesNotStopOthersAndRetryReRunsOnlyFailed() async throws {
        let good = try await makeRepo("good", files: ["g.txt": "g\n"])
        let bad = try await makeRepo("bad", files: ["b.txt": "b\n"])
        let main = try await makeRepo("main")
        try await g(main, ["submodule", "add", "-q", "file://" + bad.path, "a-bad"])
        try await g(main, ["submodule", "add", "-q", "file://" + good.path, "b-good"])
        try await g(main, ["commit", "-q", "-m", "subs"])
        // Break the first submodule's source after the superproject was committed.
        let moved = root.appendingPathComponent("bad-moved")
        try FileManager.default.moveItem(at: bad, to: moved)

        let dest = root.appendingPathComponent("dest")
        let ev = try await collect(Clone.run("file://" + main.path, into: dest, options: opts))
        XCTAssertEqual(ev.last, .finished(failedSubmodules: ["a-bad"]))
        let rs = results(ev)
        XCTAssertEqual(rs.map(\.path), ["a-bad", "b-good"])
        XCTAssertFalse(rs[0].ok); XCTAssertNotNil(rs[0].error)
        XCTAssertTrue(rs[1].ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("b-good/g.txt").path))

        // Repair the source, retry only the failed one.
        try FileManager.default.moveItem(at: moved, to: bad)
        let again = await Clone.retrySubmodules(["a-bad"], in: GitRepository(url: dest), options: opts)
        XCTAssertEqual(again.map(\.path), ["a-bad"]); XCTAssertTrue(again[0].ok, again[0].error ?? "")
        let states = try await GitRepository(url: dest).submodules().map(\.state)
        XCTAssertEqual(states, [.clean, .clean])
    }

    func testCancelledCloneIsRemoved() async throws {
        var o = opts; o.gitConfig["protocol.ext.allow"] = "always"
        let dest = root.appendingPathComponent("dest")
        let started = Date()
        let task = Task { _ = try? await collect(Clone.run("ext::sleep 30", into: dest, options: o)) }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel(); await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "cancel must kill the transport, not wait it out")
        // Cleanup runs on the clone's own task after the consumer has gone, so allow it a moment.
        for _ in 0..<50 where FileManager.default.fileExists(atPath: dest.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testNonEmptyDestinationIsRefusedAndLeftAlone() async throws {
        let src = try await makeRepo("src")
        let dest = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "keep".write(to: dest.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        do { _ = try await collect(Clone.run("file://" + src.path, into: dest, options: opts)); XCTFail("should refuse") } catch {}
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("mine.txt")), "keep")
    }

    func testFailedCloneRemovesWhatItCreatedButKeepsAPreexistingEmptyDir() async throws {
        let missing = root.appendingPathComponent("nope")
        let fresh = root.appendingPathComponent("fresh"), empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        for d in [fresh, empty] { do { _ = try await collect(Clone.run("file://" + missing.path, into: d, options: opts)); XCTFail() } catch {} }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testSparseCheckoutLimitsWorkingTree() async throws {
        let src = try await makeRepo("src", files: ["keep/x.txt": "x\n", "other/y.txt": "y\n"])
        var o = opts; o.sparsePaths = ["keep"]
        let dest = root.appendingPathComponent("dest")
        _ = try await collect(Clone.run("file://" + src.path, into: dest, options: o))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("keep/x.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("other").path))
    }

    func testLFSDetectionFromGitattributesAndEventOrdering() async throws {
        let plain = try await makeRepo("plain")
        let plainUsesLFS = await GitRepository(url: plain).usesLFS()
        XCTAssertFalse(plainUsesLFS)
        let lfs = try await makeRepo("lfs", files: [".gitattributes": "*.bin filter=lfs diff=lfs merge=lfs -text\n", "a.txt": "a\n"])
        let lfsUsesLFS = await GitRepository(url: lfs).usesLFS()
        XCTAssertTrue(lfsUsesLFS)
        let dest = root.appendingPathComponent("dest")
        var o = opts; o.lfs = .onDemand      // no smudge, so this works with or without git-lfs installed
        let ev = try await collect(Clone.run("file://" + lfs.path, into: dest, options: o))
        XCTAssertTrue(ev.contains(.lfsDetected(gitLFSInstalled: Shell.which("git-lfs") != nil)))
        XCTAssertEqual(ev.last, .finished(failedSubmodules: []))
    }

    func testOnDemandKeepsPointerFilesWhenGitLFSIsInstalled() async throws {
        try XCTSkipIf(Shell.which("git-lfs") == nil, "git-lfs not installed")
        let src = try await makeRepo("lfs", files: [".gitattributes": "*.bin filter=lfs diff=lfs merge=lfs -text\n"])
        try Data(repeating: 7, count: 4096).write(to: src.appendingPathComponent("big.bin"))
        try await g(src, ["lfs", "install", "--local"]); try await g(src, ["add", "-A"]); try await g(src, ["commit", "-q", "-m", "bin"])
        var o = opts; o.lfs = .onDemand
        let dest = root.appendingPathComponent("dest")
        _ = try await collect(Clone.run("file://" + src.path, into: dest, options: o))
        let text = try String(contentsOf: dest.appendingPathComponent("big.bin"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("version https://git-lfs.github.com/spec/v1"), "expected a pointer file")
        let lfsSize = await GitRepository(url: dest).lfsTotalSize()
        XCTAssertNotNil(lfsSize)
    }

    // MARK: Parsers and argument building
    func testSubmoduleStatusParsing() {
        let t = " 1111111111111111111111111111111111111111 a (heads/main)\n-2222222222222222222222222222222222222222 b\n+3333333333333333333333333333333333333333 c/d (v1)\nU4444444444444444444444444444444444444444 e\n"
        XCTAssertEqual(Clone.parseSubmoduleStatus(t).map(\.state), [.clean, .uninitialised, .outOfDate, .conflicting])
        XCTAssertEqual(Clone.parseSubmoduleStatus(t).map(\.path), ["a", "b", "c/d", "e"])
    }

    func testLFSSizeParsing() {
        let t = "abc123 * big.bin (1.5 MB)\ndef456 - small.bin (500 B)\nbad line\nfff * huge (2 GB)\n"
        XCTAssertEqual(Clone.parseLFSSizes(t), 1_500_000 + 500 + 2_000_000_000)
    }

    func testSSHToHTTPSRewriteIsAPerCommandConfigNotGlobal() {
        var o = CloneOptions(); o.sshToHTTPS = true
        let a = Clone.configArgs(o)
        XCTAssertTrue(a.contains("url.https://github.com/.insteadOf=git@github.com:"))
        XCTAssertEqual(a.filter { $0 == "-c" }.count, 3)
        XCTAssertTrue(Clone.configArgs(CloneOptions()).isEmpty)
    }

    func testCloneArgumentsEndOptionsBeforeRemote() {
        var o = CloneOptions(); o.filter = "blob:none"; o.depth = 5
        let a = Clone.cloneArgs("--upload-pack=evil", URL(fileURLWithPath: "/tmp/x"), o)
        XCTAssertEqual(a.suffix(3), ["--", "--upload-pack=evil", "/tmp/x"])
        XCTAssertTrue(a.contains("--filter=blob:none"))
    }
}
