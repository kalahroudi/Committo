import Foundation

public struct MCPTool: Sendable {
    public let name: String, description: String, schema: JSONValue
    public let handler: @Sendable (JSONValue) async throws -> String
}

/// Stdio MCP server exposing Committo to agents (Claude Code, Cursor, Codex, ...).
/// Tools are repo-scoped via `repo` (path); omitted → most recent repo.
public final class MCPServer: @unchecked Sendable {
    public let tools: [MCPTool]
    public init(tools: [MCPTool] = MCPServer.defaultTools()) { self.tools = tools }

    public func serveStdio() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let msg = JSONValue.parse(line) else { continue }
            if let reply = await handle(msg) { FileHandle.standardOutput.write(Data((reply.serialized() + "\n").utf8)) }
        }
    }

    public func handle(_ m: JSONValue) async -> JSONValue? {
        guard let method = m["method"]?.string else { return nil }
        guard let id = m["id"] else { return nil }   // notifications get no reply
        func ok(_ r: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": id, "result": r] }
        func fail(_ code: Int, _ msg: String) -> JSONValue { ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(msg)]] }
        switch method {
        case "initialize":
            return ok(["protocolVersion": m["params"]?["protocolVersion"] ?? "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "committo", "version": "0.1.0"]])
        case "ping": return ok([:])
        case "tools/list":
            return ok(["tools": .array(tools.map { ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema] })])
        case "tools/call":
            guard let name = m["params"]?["name"]?.string, let tool = tools.first(where: { $0.name == name }) else { return fail(-32602, "Unknown tool") }
            do {
                let text = try await tool.handler(m["params"]?["arguments"] ?? [:])
                return ok(["content": [["type": "text", "text": .string(text)]]])
            } catch {
                return ok(["content": [["type": "text", "text": .string("Error: \(error.localizedDescription)")]], "isError": true])
            }
        default: return fail(-32601, "Method not found")
        }
    }

    // MARK: Tools
    static func schema(_ props: [String: (String, String)], required: [String] = []) -> JSONValue {
        .object(["type": "object", "properties": .object(props.mapValues { ["type": .string($0.0), "description": .string($0.1)] }), "required": .array(required.map(JSONValue.string))])
    }
    static func repo(_ a: JSONValue) throws -> GitRepository {
        if let p = a["repo"]?.string { let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath); guard GitRepository.isRepository(u) else { throw ProviderError(message: "Not a git repo: \(p)") }; return GitRepository(url: u) }
        if let r = RepoStore.shared.all().first(where: { GitRepository.isRepository($0.url) }) { return GitRepository(url: r.url) }
        throw ProviderError(message: "No repo given and no recent repos known")
    }
    static func finding(_ f: Finding) -> String { "[\(f.severity.label)] \(f.title) — \(f.file):\(f.line) — \(f.advice)" }

    public static func defaultTools() -> [MCPTool] {
        let repoProp = ("string", "Repository path (default: most recent repo)")
        return [
            MCPTool(name: "list_recent_repos", description: "List recently used git repositories with branch and dirty state.", schema: schema([:])) { _ in
                var out: [String] = []
                for r in RepoStore.shared.all().prefix(15) { if let s = await RepoStore.shared.summary(r) { out.append("\(r.path)  [\(s.branch)] dirty:\(s.dirty) ↑\(s.ahead) ↓\(s.behind)") } }
                return out.isEmpty ? "No repos known. Open one in Committo first." : out.joined(separator: "\n")
            },
            MCPTool(name: "repo_status", description: "Branch, upstream sync and changed files.", schema: schema(["repo": repoProp])) { a in
                let s = try await repo(a).status()
                return "branch \(s.branch)" + (s.upstream.map { " → \($0) (↑\(s.ahead) ↓\(s.behind))" } ?? "") + "\n" + s.changes.map { "\($0.staged ? "S" : "W") \($0.kind.rawValue) \($0.path)" }.joined(separator: "\n")
            },
            MCPTool(name: "repo_log", description: "Recent commits.", schema: schema(["repo": repoProp, "limit": ("integer", "Max commits (default 20)"), "path": ("string", "Limit to file")])) { a in
                try await repo(a).log(limit: a["limit"]?.int ?? 20, all: false, path: a["path"]?.string).map { "\($0.shortHash) \($0.author): \($0.subject)" }.joined(separator: "\n")
            },
            MCPTool(name: "repo_diff", description: "Unified diff of working tree (or staged).", schema: schema(["repo": repoProp, "staged": ("boolean", "Staged changes only")])) { a in
                let r = try repo(a)
                return try await Shell.check("git", ["diff", "--no-color"] + (a["staged"]?.bool == true ? ["--cached"] : []), cwd: r.url)
            },
            MCPTool(name: "security_scan", description: "Scan uncommitted changes for secrets, risky code patterns and CI red flags.", schema: schema(["repo": repoProp])) { a in
                let f = try await SecurityScanner().scanWorkingTree(repo(a))
                return f.isEmpty ? "No findings." : f.map(finding).joined(separator: "\n")
            },
            MCPTool(name: "agent_lens", description: "What agents are doing: branches/worktrees with agent attribution, size and liveness.", schema: schema(["repo": repoProp])) { a in
                let items = await AgentLens.scan(try repo(a))
                return items.isEmpty ? "No agent branches." : items.map { "\($0.isLive ? "● " : "")\($0.agent.displayName) \($0.branch) — \($0.commits.count) commits, \($0.filesChanged) files +\($0.additions)/-\($0.deletions)" + ($0.worktree.map { " @ \($0)" } ?? "") }.joined(separator: "\n")
            },
            MCPTool(name: "securitycage_status", description: "SecurityCage install state: pinned version, Node/npm/container readiness, and whether an update is available.", schema: schema([:])) { _ in
                let sc = SecurityCageManager(); let st = await sc.status()
                var out = "node: \(st.node ?? "missing")\(st.nodeOK ? "" : " (need 22.18+)")  npm: \(st.npm)  container: \(st.container ?? "none")\n"
                out += st.pin.map { "installed \($0.label) (\($0.repo))" } ?? "not installed"
                if st.pin != nil, let u = try? await sc.checkForUpdate() { out += "\nupdate available: \(u.commitsBehind) commit(s) behind -> \(u.remote.sha.prefix(7)) \(u.remote.message)" }
                return out
            },
            MCPTool(name: "securitycage_install", description: "Install SecurityCage pinned to the latest commit SHA (or `sha`). Runs npm ci --ignore-scripts and a self-test before activating. Also used to update.", schema: schema(["sha": ("string", "Specific commit SHA (default: latest)")])) { a in
                let pin = try await SecurityCageManager().install(sha: a["sha"]?.string)
                return "Installed \(pin.label) (sha256 \(pin.tarballSHA256.prefix(12))…)"
            },
            MCPTool(name: "securitycage_scan", description: "Run SecurityCage's free offline plan on a repo or PR checkout. Pass `changed_files` to scope to a pull request. PR code is treated as untrusted by default.",
                    schema: schema(["repo": repoProp, "changed_files": ("array", "Paths changed by the PR"), "trust_repo_config": ("boolean", "Only for repos you own")])) { a in
                let r = try repo(a)
                let changed = a["changed_files"]?.array?.compactMap(\.string)
                let res = try await SecurityCageManager().plan(repo: r.url, changed: changed, untrusted: a["trust_repo_config"]?.bool != true)
                if res.findings.isEmpty { return "No items. \(res.surfaces) entry point(s) checked." }
                return res.findings.prefix(5).map { "[\($0.severity.label) · \($0.certainty ?? "?")] \($0.title) — \($0.file)\n  fix: \($0.fixPrompt ?? $0.advice)" }.joined(separator: "\n") + "\n\(res.findings.count) item(s) total."
            },
            MCPTool(name: "create_branch", description: "Create and switch to a new branch.", schema: schema(["repo": repoProp, "name": ("string", "Branch name")], required: ["name"])) { a in
                guard let n = a["name"]?.string else { throw ProviderError(message: "name required") }
                try await repo(a).createBranch(n); return "Switched to \(n)"
            },
            MCPTool(name: "commit_all", description: "Stage everything and commit.", schema: schema(["repo": repoProp, "message": ("string", "Commit message")], required: ["message"])) { a in
                guard let m = a["message"]?.string else { throw ProviderError(message: "message required") }
                let r = try repo(a)
                let findings = try await SecurityScanner().scanWorkingTree(r).filter { $0.severity >= .high }
                if !findings.isEmpty { throw ProviderError(message: "Refusing to commit — high-severity findings:\n" + findings.map(finding).joined(separator: "\n")) }
                try await r.stageAll(); try await r.commit(m); return "Committed."
            },
            MCPTool(name: "ci_list_workflows", description: "List GitHub Actions jobs runnable locally via act.", schema: schema(["repo": repoProp])) { a in
                try await ActRunner().workflows(in: repo(a).url).map { "\($0.file) :: \($0.job) (\($0.events))" }.joined(separator: "\n")
            },
            MCPTool(name: "ci_run", description: "Run a workflow/job locally with act (or on a LAN runner if `server` is set). Returns the log tail.",
                    schema: schema(["repo": repoProp, "workflow": ("string", "Workflow file name"), "job": ("string", "Job id"), "event": ("string", "Event (default push)"), "server": ("string", "Name of configured LAN CI server")])) { a in
                let r = try repo(a)
                var req = CIRunRequest(repoPath: r.url.path, workflowFile: a["workflow"]?.string, job: a["job"]?.string, event: a["event"]?.string ?? "push")
                req.dryRun = false
                let runner: CIRunner
                if let s = a["server"]?.string, let cfg = CIServerStore.load().first(where: { $0.name == s }), let rr = cfg.runner() { runner = rr } else { runner = ActRunner() }
                var log: [String] = [], ok = false
                for try await e in runner.run(req) { switch e { case .log(let l): log.append(l); case .finished(let s): ok = s } }
                return (ok ? "PASSED" : "FAILED") + "\n" + log.suffix(80).joined(separator: "\n")
            },
        ]
    }
}

public enum CIServerStore {
    static var file: URL { RepoStore.supportDirectory.appendingPathComponent("ci-servers.json") }
    public static func load() -> [CIServerConfig] { (try? JSONDecoder().decode([CIServerConfig].self, from: Data(contentsOf: file))) ?? [] }
    public static func save(_ s: [CIServerConfig]) { try? JSONEncoder().encode(s).write(to: file, options: .atomic) }
}
