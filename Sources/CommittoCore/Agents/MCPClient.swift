import Foundation

public struct MCPServerConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String] = [:]
    public init(name: String, command: String, args: [String], env: [String: String] = [:]) { self.name = name; self.command = command; self.args = args; self.env = env }
}

public struct MCPToolInfo: Hashable, Sendable { public let name: String; public let description: String; public let schema: JSONValue }

/// Minimal stdio MCP client (JSON-RPC 2.0, newline-delimited). Used for the "MCP bridge" to third-party agents.
/// The server runs under the process supervisor: `stop()`, a cancelled bridge task or app quit kill its whole process tree.
public actor MCPClient {
    private let config: MCPServerConfig
    private let path: String
    private var process: ProcessSupervisor.Managed?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var exited = false
    /// Replies larger than this are dropped (the request then fails by timeout instead of buffering without bound).
    static let maxMessage = 16 << 20
    public var requestTimeout: TimeInterval = 120

    public init(config: MCPServerConfig) throws {
        guard let path = Shell.which(config.command) else { throw ProviderError(message: "`\(config.command)` not found") }
        self.config = config; self.path = path
    }

    public func setRequestTimeout(_ t: TimeInterval) { requestTimeout = t }

    public func start() async throws {
        let splitter = RecordSplitter(maxRecord: Self.maxMessage) { [weak self] data, truncated in
            guard !truncated else { return }
            Task { await self?.ingest(data) }
        }
        process = try ProcessSupervisor.shared.launch(
            path: path, args: config.args, cwd: nil, env: Shell.environment(config.env), wantStdin: true, mergeStderr: false, timeout: nil,
            onOutput: { data, isErr in if !isErr { splitter.feed(data) }; return true },
            onExit: { [weak self] _ in splitter.finish(); Task { await self?.serverExited() } })
        _ = try await request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "committo", "version": "0.1.0"]])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    /// Kills the server and its children and fails any request still waiting.
    public func stop() {
        process?.terminate()
        failAll(ProviderError(message: "MCP server stopped"))
    }

    func serverExited() {
        exited = true
        failAll(ProviderError(message: "MCP server `\(config.name)` exited"))
    }

    private func failAll(_ error: Error) {
        let all = pending; pending = [:]
        timers.values.forEach { $0.cancel() }; timers = [:]
        for (_, c) in all { c.resume(throwing: error) }
    }

    func ingest(_ line: Data) {
        guard let j = try? JSONDecoder().decode(JSONValue.self, from: line), let id = j["id"]?.int, let c = pending.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        if let e = j["error"] { c.resume(throwing: ProviderError(message: e["message"]?.string ?? "MCP error")) } else { c.resume(returning: j["result"] ?? .null) }
    }

    func send(_ v: JSONValue) throws {
        guard let process, !exited else { throw ProviderError(message: "MCP server `\(config.name)` is not running") }
        try process.write(Data((v.serialized() + "\n").utf8))
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let id = nextID; nextID += 1
        let timeout = requestTimeout
        let name = config.name
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            do { try send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]) }
            catch { pending[id] = nil; c.resume(throwing: error); return }
            timers[id] = Task { [weak self] in
                guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else { return }
                await self?.timeOut(id, method: method, server: name, seconds: timeout)
            }
        }
    }

    private func timeOut(_ id: Int, method: String, server: String, seconds: TimeInterval) {
        timers[id] = nil
        pending.removeValue(forKey: id)?.resume(throwing: ProviderError(message: "MCP server `\(server)` did not answer `\(method)` within \(Int(seconds)) s"))
    }

    public func listTools() async throws -> [MCPToolInfo] {
        try await request("tools/list", [:])["tools"]?.array?.map { MCPToolInfo(name: $0["name"]?.string ?? "", description: $0["description"]?.string ?? "", schema: $0["inputSchema"] ?? .null) } ?? []
    }
    public func call(_ tool: String, arguments: JSONValue) async throws -> String {
        let r = try await request("tools/call", ["name": .string(tool), "arguments": arguments])
        return (r["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
    }
}

/// Wraps any MCP server tool as an agent: `promptArgument` receives the task prompt.
public struct MCPBridgeBackend: AgentBackend, Codable {
    public var id: String, displayName: String
    public var kind: AgentKind = .other
    public var server: MCPServerConfig
    public var tool: String
    public var promptArgument: String
    public var isAvailable: Bool { Shell.which(server.command) != nil }
    public init(id: String, displayName: String, server: MCPServerConfig, tool: String, promptArgument: String = "prompt") {
        self.id = id; self.displayName = displayName; self.server = server; self.tool = tool; self.promptArgument = promptArgument
    }
    public func run(_ task: AgentTask) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    var cfg = server; cfg.env["COMMITTO_REPO"] = task.workingDirectory.path
                    let client = try MCPClient(config: cfg)
                    do {
                        try await withTaskCancellationHandler {
                            try await client.start()
                            cont.yield(.toolUse(name: tool, summary: server.name))
                            let out = try await client.call(tool, arguments: .object([promptArgument: .string(task.prompt)]))
                            await client.stop()
                            cont.yield(.text(out)); cont.yield(.finished(AgentResult(text: out))); cont.finish()
                        } onCancel: { Task { await client.stop() } }
                    } catch { await client.stop(); throw error }
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}
