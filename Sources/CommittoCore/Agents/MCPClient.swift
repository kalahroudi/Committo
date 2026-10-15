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
public actor MCPClient {
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var buffer = Data()

    public init(config: MCPServerConfig) throws {
        guard let path = Shell.which(config.command) else { throw ProviderError(message: "`\(config.command)` not found") }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = config.args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.searchPath.joined(separator: ":")
        for (k, v) in config.env { env[k] = v }
        process.environment = env
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
    }

    public func start() async throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            Task { await self.ingest(d) }
        }
        try process.run()
        _ = try await request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "committo", "version": "0.1.0"]])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }
    public func stop() { stdout.fileHandleForReading.readabilityHandler = nil; if process.isRunning { process.terminate() } }

    func ingest(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]; buffer = Data(buffer[buffer.index(after: nl)...])
            guard let j = try? JSONDecoder().decode(JSONValue.self, from: Data(line)), let id = j["id"]?.int, let c = pending.removeValue(forKey: id) else { continue }
            if let e = j["error"] { c.resume(throwing: ProviderError(message: e["message"]?.string ?? "MCP error")) } else { c.resume(returning: j["result"] ?? .null) }
        }
    }
    func send(_ v: JSONValue) throws { stdin.fileHandleForWriting.write(Data((v.serialized() + "\n").utf8)) }
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let id = nextID; nextID += 1
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            do { try send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]) } catch { pending[id] = nil; c.resume(throwing: error) }
        }
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
                    try await client.start()
                    cont.yield(.toolUse(name: tool, summary: server.name))
                    let out = try await client.call(tool, arguments: .object([promptArgument: .string(task.prompt)]))
                    await client.stop()
                    cont.yield(.text(out)); cont.yield(.finished(AgentResult(text: out))); cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}
