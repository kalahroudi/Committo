import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AgentTask: Sendable {
    public var prompt: String
    public var workingDirectory: URL
    public var readOnly: Bool = true          // review/plan style: no edits
    public var maxTurns: Int? = nil
    public var model: String? = nil
    public var resumeSession: String? = nil
    public init(prompt: String, workingDirectory: URL, readOnly: Bool = true, maxTurns: Int? = nil, model: String? = nil, resumeSession: String? = nil) {
        self.prompt = prompt; self.workingDirectory = workingDirectory; self.readOnly = readOnly; self.maxTurns = maxTurns; self.model = model; self.resumeSession = resumeSession
    }
}

public enum AgentEvent: Sendable {
    case text(String)
    case toolUse(name: String, summary: String)
    case toolResult(String)
    case finished(AgentResult)
}
public struct AgentResult: Sendable { public var text: String; public var costUSD: Double?; public var sessionID: String?; public var turns: Int? }

public protocol AgentBackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    var kind: AgentKind { get }
    var isAvailable: Bool { get }
    func run(_ task: AgentTask) -> AsyncThrowingStream<AgentEvent, Error>
}

public extension AgentBackend {
    /// Convenience: run to completion and return the final text.
    func complete(_ task: AgentTask) async throws -> AgentResult {
        var text = "", result: AgentResult?
        for try await e in run(task) {
            switch e { case .text(let t): text += t; case .finished(let r): result = r; default: break }
        }
        return result ?? AgentResult(text: text)
    }
}

// MARK: Claude Code, headless

/// Drives the `claude` CLI in print mode with streaming JSON so Committo can show live tool use.
public struct ClaudeCodeBackend: AgentBackend {
    public let id = "claude-code", displayName = "Claude Code (headless)", kind = AgentKind.claude
    public var executable: String
    public var extraArgs: [String]
    public init(executable: String = "claude", extraArgs: [String] = []) { self.executable = executable; self.extraArgs = extraArgs }
    public var isAvailable: Bool { Shell.which(executable) != nil }

    public func arguments(for task: AgentTask) -> [String] {
        var a = ["-p", task.prompt, "--output-format", "stream-json", "--verbose"]
        if task.readOnly {
            a += ["--permission-mode", "plan", "--allowedTools", "Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*)"]
        } else { a += ["--permission-mode", "acceptEdits"] }
        if let n = task.maxTurns { a += ["--max-turns", "\(n)"] }
        if let m = task.model { a += ["--model", m] }
        if let s = task.resumeSession { a += ["--resume", s] }
        return a + extraArgs
    }

    public func run(_ task: AgentTask) -> AsyncThrowingStream<AgentEvent, Error> {
        let lines = Shell.stream(executable, arguments(for: task), cwd: task.workingDirectory)
        return AsyncThrowingStream { cont in
            let t = Task {
                do {
                    var finalText = ""
                    for try await line in lines {
                        guard line.hasPrefix("{"), let j = JSONValue.parse(line) else { continue }
                        switch j["type"]?.string {
                        case "assistant":
                            for block in j["message"]?["content"]?.array ?? [] {
                                if block["type"]?.string == "text", let t = block["text"]?.string { finalText += t; cont.yield(.text(t)) }
                                if block["type"]?.string == "tool_use" {
                                    let input = block["input"]
                                    let summary = input?["command"]?.string ?? input?["file_path"]?.string ?? input?["pattern"]?.string ?? input?["path"]?.string ?? ""
                                    cont.yield(.toolUse(name: block["name"]?.string ?? "tool", summary: summary))
                                }
                            }
                        case "user":
                            for block in j["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                                cont.yield(.toolResult(String((block["content"]?.string ?? "").prefix(400))))
                            }
                        case "result":
                            cont.yield(.finished(AgentResult(text: j["result"]?.string ?? finalText, costUSD: j["total_cost_usd"]?.double, sessionID: j["session_id"]?.string, turns: j["num_turns"]?.int)))
                        default: break
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

// MARK: Any CLI agent

/// Generic adapter for agent CLIs (Codex, Gemini CLI, Aider, Command Code, dsh, ...). `{prompt}` is substituted in args.
/// Defaults are editable in Settings; verify flags against each tool's `--help`.
public struct CLIAgentBackend: AgentBackend, Codable {
    public var id: String
    public var displayName: String
    public var kind: AgentKind
    public var command: String
    public var args: [String]
    public var isAvailable: Bool { Shell.which(command) != nil }

    public init(id: String, displayName: String, kind: AgentKind = .other, command: String, args: [String]) {
        self.id = id; self.displayName = displayName; self.kind = kind; self.command = command; self.args = args
    }
    public static let presets: [CLIAgentBackend] = [
        .init(id: "codex", displayName: "OpenAI Codex CLI", kind: .codex, command: "codex", args: ["exec", "{prompt}"]),
        .init(id: "gemini", displayName: "Gemini CLI", kind: .gemini, command: "gemini", args: ["-p", "{prompt}"]),
        .init(id: "aider", displayName: "Aider", kind: .aider, command: "aider", args: ["--message", "{prompt}", "--no-pretty", "--yes-always"]),
        .init(id: "command-code", displayName: "Command Code", kind: .commandCode, command: "cmd", args: ["-p", "{prompt}"]),
        .init(id: "dsh", displayName: "dsh", kind: .other, command: "dsh", args: ["{prompt}"]),
    ]
    public func run(_ task: AgentTask) -> AsyncThrowingStream<AgentEvent, Error> {
        let lines = Shell.stream(command, args.map { $0.replacingOccurrences(of: "{prompt}", with: task.prompt) }, cwd: task.workingDirectory)
        return AsyncThrowingStream { cont in
            let t = Task {
                var all = ""
                do { for try await l in lines { all += l + "\n"; cont.yield(.text(l + "\n")) }
                    cont.yield(.finished(AgentResult(text: all))); cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

// MARK: Direct API

public struct APIAgentBackend: AgentBackend, Codable {
    public enum Flavor: String, Codable, CaseIterable, Sendable { case anthropic, openAICompatible }
    public var id: String, displayName: String
    public var kind: AgentKind
    public var flavor: Flavor
    public var baseURL: String
    public var model: String
    public var keychainAccount: String
    public var isAvailable: Bool { Keychain.get(keychainAccount) != nil }

    public static func anthropic(model: String = "claude-sonnet-5-5") -> Self {
        .init(id: "anthropic-api", displayName: "Anthropic API", kind: .claude, flavor: .anthropic, baseURL: "https://api.anthropic.com", model: model, keychainAccount: "agent.anthropic")
    }
    public static func openAI(model: String = "gpt-5") -> Self {
        .init(id: "openai-api", displayName: "OpenAI-compatible API", kind: .codex, flavor: .openAICompatible, baseURL: "https://api.openai.com/v1", model: model, keychainAccount: "agent.openai")
    }

    /// Single-shot completion (no tools) — ideal for PR review, commit messages and summaries.
    public func run(_ task: AgentTask) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    guard let key = Keychain.get(keychainAccount) else { throw ProviderError(message: "No API key for \(displayName)") }
                    var req: URLRequest
                    var body: JSONValue
                    switch flavor {
                    case .anthropic:
                        req = URLRequest(url: URL(string: baseURL + "/v1/messages")!)
                        req.setValue(key, forHTTPHeaderField: "x-api-key"); req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                        body = ["model": .string(task.model ?? model), "max_tokens": 4096, "messages": [["role": "user", "content": .string(task.prompt)]]]
                    case .openAICompatible:
                        req = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        body = ["model": .string(task.model ?? model), "messages": [["role": "user", "content": .string(task.prompt)]]]
                    }
                    req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.httpBody = body.serialized().data(using: .utf8)
                    let j = try await HTTP.json(req)
                    let text = flavor == .anthropic ? (j["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined() : (j["choices"]?[0]?["message"]?["content"]?.string ?? "")
                    cont.yield(.text(text)); cont.yield(.finished(AgentResult(text: text))); cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

// MARK: Registry

public struct AgentRegistry: Sendable {
    public var backends: [AgentBackend]
    public init(backends: [AgentBackend]? = nil) {
        self.backends = backends ?? ([ClaudeCodeBackend(), APIAgentBackend.anthropic(), APIAgentBackend.openAI()] as [AgentBackend]) + CLIAgentBackend.presets
    }
    public var available: [AgentBackend] { backends.filter(\.isAvailable) }
    public func backend(id: String) -> AgentBackend? { backends.first { $0.id == id } }
    public var preferred: AgentBackend? { available.first }
}
