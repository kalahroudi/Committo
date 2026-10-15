import Foundation
import CommittoCore

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }

switch args.first {
case "mcp":
    await MCPServer().serveStdio()

case "scan":
    let path = args.dropFirst().first ?? FileManager.default.currentDirectoryPath
    let repo = GitRepository(url: URL(fileURLWithPath: path))
    let findings = try await SecurityScanner().scanWorkingTree(repo)
    for f in findings { print("[\(f.severity.label)] \(f.title) — \(f.file):\(f.line)") }
    exit(findings.contains { $0.severity >= .high } ? 1 : 0)

case "ci-serve":
    #if canImport(Network)
    let token = flag("--token") ?? ProcessInfo.processInfo.environment["COMMITTO_CI_TOKEN"] ?? {
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: ""); print("Generated token: \(t)"); return t }()
    let port = UInt16(flag("--port") ?? "7771") ?? 7771
    let server = CIServer(port: port, token: token)
    try server.start()
    print("Committo CI runner listening on :\(port) (Bonjour: _committo-ci._tcp). act installed: \(ActRunner.isInstalled)")
    dispatchMain()
    #else
    print("ci-serve requires macOS"); exit(2)
    #endif

default:
    print("""
    committo — companion CLI for the Committo app

      committo mcp                      Run the MCP server on stdio (add to Claude Code, Cursor, Codex, ...)
      committo scan [path]              Security-scan uncommitted changes (exit 1 on high/critical)
      committo ci-serve [--port N] [--token T]
                                        Serve this machine as a LAN CI runner (needs act + Docker)

    Claude Code:  claude mcp add committo -- \(CommandLine.arguments[0]) mcp
    """)
}
