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

case "securitycage":
    let sc = SecurityCageManager()
    let sub = args.dropFirst().first ?? "status"
    switch sub {
    case "status":
        let st = await sc.status()
        print("node: \(st.node ?? "not found") \(st.nodeOK ? "ok" : "(need 22.18+)")  npm: \(st.npm)  containers (for --prove): \(st.container ?? "none")")
        if let p = st.pin { print("installed: \(p.label) from \(p.repo) on \(p.installedAt)  healthy: \(st.healthy)") } else { print("not installed") }
        if st.pin != nil, let u = try? await sc.checkForUpdate() {
            print("update available: \(u.commitsBehind) commit(s) behind -> \(u.remote.sha.prefix(7)) \(u.remote.message)")
            u.headlines.forEach { print("  - \($0)") }
        }
    case "install", "update":
        let shaArg = args.dropFirst(2).first
        do { let pin = try await (sub == "install" ? sc.install(sha: shaArg) { print("==> \($0)") } : sc.update { print("==> \($0)") }); print("pinned \(pin.label)  sha256 \(pin.tarballSHA256.prefix(12))…") }
        catch { print("error: \(error.localizedDescription)"); exit(1) }
    case "rollback":
        do { try sc.rollback(); print("rolled back to \(sc.pin()?.label ?? "?")") } catch { print("error: \(error.localizedDescription)"); exit(1) }
    case "scan":
        let path = args.dropFirst(2).first ?? FileManager.default.currentDirectoryPath
        do {
            let r = try await sc.plan(repo: URL(fileURLWithPath: path))
            for f in r.findings.prefix(5) { print("[\(f.severity.label) · \(f.certainty ?? "?")] \(f.title) — \(f.file)") }
            print("\(r.findings.count) item(s), \(r.surfaces) entry point(s). Report: \(r.outDir)/report.html")
            exit(r.findings.contains { $0.severity >= .high } ? 1 : 0)
        } catch { print("error: \(error.localizedDescription)"); exit(3) }
    default: print("usage: committo securitycage [status|install [sha]|update|rollback|scan <path>]")
    }

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
      committo securitycage [status|install [sha]|update|rollback|scan <path>]
                                        Install/pin/update SecurityCage and scan a repo or PR checkout
      committo ci-serve [--port N] [--token T]
                                        Serve this machine as a LAN CI runner (needs act + Docker)

    Claude Code:  claude mcp add committo -- \(CommandLine.arguments[0]) mcp
    """)
}
