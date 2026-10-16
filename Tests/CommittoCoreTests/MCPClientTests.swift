import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import CommittoCore

/// The MCP client runs its server under the process supervisor. Fake servers are tiny `sh` scripts.
final class MCPClientTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("committo-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProcessSupervisor.shared.killGrace = 1
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        let end = Date().addingTimeInterval(5)
        while ProcessSupervisor.shared.liveCount > 0 && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(ProcessSupervisor.shared.liveCount, 0)
    }

    /// Answers every request that has an id with a tools/list-shaped result. `extra` runs before the loop.
    func server(extra: String = "", reply: Bool = true) -> MCPServerConfig {
        let body = reply
            ? #"while IFS= read -r line; do id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p'); [ -n "$id" ] && printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"d","inputSchema":{}}]}}\n' "$id"; done"#
            : "cat >/dev/null"
        return MCPServerConfig(name: "fake", command: "sh", args: ["-c", extra + "\n" + body])
    }
    func isAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")"), stat[stat.index(close, offsetBy: 2)...].first == "Z" { return false }
        return true
    }
    func waitGone(_ pid: pid_t) async throws {
        let end = Date().addingTimeInterval(5)
        while isAlive(pid) && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(isAlive(pid), "process \(pid) survived")
    }

    func testHandshakeAndListTools() async throws {
        let c = try MCPClient(config: server())
        try await c.start()
        let tools = try await c.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        await c.stop()
    }

    func testStopKillsServerChildren() async throws {
        let pidFile = dir.appendingPathComponent("child.pid")
        let c = try MCPClient(config: server(extra: "sleep 60 & echo $! > '\(pidFile.path)'"))
        try await c.start()
        var text = ""
        for _ in 0..<100 { text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""; if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertTrue(isAlive(pid))
        await c.stop()
        try await waitGone(pid)
    }

    func testServerExitFailsPendingRequest() async throws {
        // Replies to initialize, then dies on the next line.
        let script = #"read -r line; id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p'); printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"; read -r _; read -r _; exit 0"#
        let c = try MCPClient(config: MCPServerConfig(name: "dies", command: "sh", args: ["-c", script]))
        try await c.start()
        do { _ = try await c.listTools(); XCTFail("expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("exited") || error.localizedDescription.contains("not running"), "\(error)") }
    }

    func testSilentServerTimesOut() async throws {
        let c = try MCPClient(config: server(reply: false))
        await c.setRequestTimeout(0.5)
        do { try await c.start(); XCTFail("expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not answer"), "\(error)") }
        await c.stop()
    }

    func testBridgeCancellationKillsServer() async throws {
        let pidFile = dir.appendingPathComponent("bridge.pid")
        let cfg = server(extra: "sleep 60 & echo $! > '\(pidFile.path)'")
        let bridge = MCPBridgeBackend(id: "b", displayName: "b", server: cfg, tool: "echo")
        let task = Task {
            for try await _ in bridge.run(AgentTask(prompt: "x", workingDirectory: dir)) {}
        }
        var text = ""
        for _ in 0..<100 { text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""; if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        _ = try? await task.value
        if let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { try await waitGone(pid) }
    }
}
