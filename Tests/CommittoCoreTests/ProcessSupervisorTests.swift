import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import CommittoCore

/// Process hygiene (QUALITY.md): after every operation and every cancel the supervisor is back to zero
/// children, and no descendant of a supervised command survives.
final class ProcessSupervisorTests: XCTestCase {
    var dir: URL!
    let sup = ProcessSupervisor.shared

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("committo-sup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sup.killGrace = 1
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await waitUntil("supervisor idle") { self.sup.liveCount == 0 }
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() { if Date() > end { XCTFail("timed out waiting for: \(what)"); return }; try await Task.sleep(nanoseconds: 50_000_000) }
    }
    /// Alive means running. A killed orphan can linger as a zombie where PID 1 is not an init (CI containers); that is dead.
    func isAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")"), stat[stat.index(close, offsetBy: 2)...].first == "Z" { return false }
        return true
    }
    /// `sh` that starts a grandchild sleeper, records its pid in a file, then sleeps itself.
    var treeScript: (script: String, pidFile: URL) {
        let f = dir.appendingPathComponent("grandchild.pid")
        return ("sleep 60 & echo $! > '\(f.path)'; sleep 60", f)
    }
    func grandchildPID(_ f: URL) async throws -> pid_t {
        try await waitUntil("pid file") { (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        return pid_t(try String(contentsOf: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    }

    func testRunCapturesStdoutStderrStatusCwdAndStdin() async throws {
        let r = try await Shell.run("sh", ["-c", "cat; echo err >&2; pwd; exit 3"], cwd: dir, stdin: "hello\n")
        XCTAssertEqual(r.status, 3)
        XCTAssertTrue(r.stdout.hasPrefix("hello\n"))
        XCTAssertEqual(r.stderr, "err\n")
        XCTAssertTrue(r.stdout.contains(dir.lastPathComponent))
    }

    func testCancelKillsTheWholeTree() async throws {
        let (script, pidFile) = treeScript
        let task = Task { try await Shell.run("sh", ["-c", script]) }
        let grandchild = try await grandchildPID(pidFile)
        XCTAssertTrue(isAlive(grandchild))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        try await waitUntil("grandchild gone") { !self.isAlive(grandchild) }
    }

    func testTimeoutKillsTreeAndThrows() async throws {
        let (script, pidFile) = treeScript
        let started = Date()
        do { _ = try await Shell.run("sh", ["-c", script], timeout: 0.5); XCTFail("expected timeout") }
        catch let ShellFailure.timedOut(_, seconds) { XCTAssertEqual(seconds, 0.5) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let grandchild = try await grandchildPID(pidFile)
        try await waitUntil("grandchild gone") { !self.isAlive(grandchild) }
    }

    func testOutputCapStopsTheProcess() async throws {
        do { _ = try await Shell.run("yes", [], maxOutput: 1 << 20); XCTFail("expected output limit") }
        catch let ShellFailure.outputLimit(_, bytes) { XCTAssertEqual(bytes, 1 << 20) }
    }

    func testOutputUnderCapIsComplete() async throws {
        let r = try await Shell.run("sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' 'a'"], maxOutput: 1 << 20)
        XCTAssertEqual(r.stdout.utf8.count, 300_000)
    }

    func testStreamBreakKillsTheProcess() async throws {
        let f = dir.appendingPathComponent("stream.pid")
        var seen = 0
        for try await _ in Shell.stream("sh", ["-c", "echo $$ > '\(f.path)'; while true; do echo tick; sleep 0.05; done"]) {
            seen += 1
            if seen == 3 { break }
        }
        let pid = try await grandchildPID(f)
        try await waitUntil("stream process gone") { !self.isAlive(pid) }
    }

    func testStreamYieldsLinesAndReportsFailure() async throws {
        var lines: [String] = []
        do {
            for try await l in Shell.stream("sh", ["-c", "echo a; echo b >&2; printf c; exit 2"]) { lines.append(l) }
            XCTFail("expected failure")
        } catch let e as ShellError { XCTAssertEqual(e.result.status, 2) }
        XCTAssertEqual(Set(lines), ["a", "b", "c"])
    }

    func testVeryLongLineIsTruncatedNotBuffered() async throws {
        var longest = 0
        for try await l in Shell.stream("sh", ["-c", "head -c 3000000 /dev/zero | tr '\\0' 'x'; echo; echo done"]) { longest = max(longest, l.utf8.count) }
        XCTAssertLessThan(longest, (1 << 20) + 64)
    }

    func testTerminateAllKillsEverything() async throws {
        let (script, pidFile) = treeScript
        let task = Task { try await Shell.run("sh", ["-c", script]) }
        let grandchild = try await grandchildPID(pidFile)
        XCTAssertGreaterThan(sup.liveCount, 0)
        sup.terminateAll()
        _ = try? await task.value
        try await waitUntil("grandchild gone") { !self.isAlive(grandchild) }
    }

    func testStragglersAreKilledWhenTheLeaderExits() async throws {
        let f = dir.appendingPathComponent("bg.pid")
        _ = try await Shell.run("sh", ["-c", "sleep 60 >/dev/null 2>&1 & echo $! > '\(f.path)'"])
        let pid = try await grandchildPID(f)
        try await waitUntil("background job gone") { !self.isAlive(pid) }
    }

    func testMissingExecutableThrows() async {
        do { _ = try await Shell.run("definitely-not-a-real-binary-xyz", []); XCTFail() } catch {}
    }
}
