import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SecurityCagePin: Codable, Equatable, Sendable {
    public var repo: String
    public var sha: String
    public var version: String
    public var installedAt: Date
    public var tarballSHA256: String
    public var node: String
    public var shortSHA: String { String(sha.prefix(7)) }
    public var label: String { "\(version)+\(shortSHA)" }
}

public struct SecurityCageRemote: Equatable, Sendable {
    public enum Source: String, Sendable { case release, head }
    public var sha: String, source: Source, tag: String?, date: Date?, message: String
}

public struct SecurityCageUpdate: Equatable, Sendable {
    public var remote: SecurityCageRemote
    public var commitsBehind: Int
    public var headlines: [String]
}

public struct SecurityCageStatus: Sendable {
    public var node: String?
    public var nodeOK: Bool
    public var npm: Bool
    public var container: String?          // "docker" / "podman" when a daemon is reachable (needed only for --prove)
    public var pin: SecurityCagePin?
    public var healthy: Bool
    public var canInstall: Bool { nodeOK && npm }
    public var problem: String? {
        if !nodeOK { return node == nil ? "Node.js 22.18+ is required" : "Node.js \(node!) is too old (22.18+ required)" }
        if !npm { return "npm is required" }
        return nil
    }
}

public struct SecurityCageResult: Sendable {
    public var findings: [Finding]
    public var surfaces: Int
    public var estimateUSD: ClosedRange<Double>?
    public var rulesRan: Bool
    public var notes: [String]
    public var outDir: String
    public var changedSurfaces: [String]
}

public enum SecurityCageError: Error, LocalizedError {
    case unavailable(String), installFailed(String), scanFailed(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let m), .installFailed(let m), .scanFailed(let m): return m }
    }
}

/// Installs, pins, updates and runs SecurityCage (github.com/kalahroudi/securitycage).
///
/// Why GitHub and not npm: the npm package named `securitycage` is an unrelated 1.0.0 placeholder, and the repo has
/// no tags or releases yet, so the *pin* is a full commit SHA. If releases appear, the latest release is preferred.
/// The code is fetched at that SHA, installed with `npm ci --ignore-scripts --omit=dev` (as its own GitHub Action does),
/// and must pass a self-test on a known-bad fixture before it becomes active. The previous pin is kept for rollback.
public final class SecurityCageManager: @unchecked Sendable {
    public let repo: String
    public let root: URL
    let api: String, codeload: String
    let session: URLSession

    public static let minNode = (major: 22, minor: 18)

    public init(repo: String = "kalahroudi/securitycage",
                root: URL = RepoStore.supportDirectory.appendingPathComponent("tools/securitycage"),
                api: String = "https://api.github.com", codeload: String = "https://codeload.github.com",
                session: URLSession = .shared) {
        self.repo = repo; self.root = root; self.api = api; self.codeload = codeload; self.session = session
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var current: URL { root.appendingPathComponent("current") }
    var stateDir: URL { root.appendingPathComponent("state") }
    var cacheDir: URL { root.appendingPathComponent("results") }
    var cli: URL { current.appendingPathComponent("packages/cli/src/cli.ts") }

    // MARK: Status

    public static func nodeAtLeastMin(_ v: String) -> Bool {
        let parts = v.trimmingCharacters(in: CharacterSet(charactersIn: "v \n")).split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return (parts[0], parts[1]) >= (minNode.major, minNode.minor)
    }

    public func pin() -> SecurityCagePin? {
        guard let d = try? Data(contentsOf: current.appendingPathComponent("committo-pin.json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SecurityCagePin.self, from: d)
    }

    public func status() async -> SecurityCageStatus {
        let node = (try? await Shell.run("node", ["-v"]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodeStr = (node?.isEmpty == false) ? node : nil
        let npm = Shell.which("npm") != nil
        var container: String?
        for rt in ["docker", "podman"] where Shell.which(rt) != nil {
            if let r = try? await Shell.run(rt, ["info"]), r.ok { container = rt; break }
        }
        let p = pin()
        let healthy = p != nil && FileManager.default.fileExists(atPath: cli.path)
        return SecurityCageStatus(node: nodeStr, nodeOK: nodeStr.map(Self.nodeAtLeastMin) ?? false, npm: npm, container: container, pin: p, healthy: healthy)
    }

    // MARK: Remote

    func getJSON(_ path: String) async throws -> JSONValue {
        var r = URLRequest(url: URL(string: api + path)!)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("Committo", forHTTPHeaderField: "User-Agent")
        if let t = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? ProcessInfo.processInfo.environment["GH_TOKEN"] { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (d, resp) = try await session.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode == 404 { return .null }
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw SecurityCageError.installFailed("GitHub API replied HTTP \(h.statusCode)") }
        return try JSONDecoder().decode(JSONValue.self, from: d)
    }

    /// Latest release if there is one, otherwise the head of the default branch.
    public func latestRemote() async throws -> SecurityCageRemote {
        let rel = try await getJSON("/repos/\(repo)/releases/latest")
        if let tag = rel["tag_name"]?.string {
            let c = try await getJSON("/repos/\(repo)/commits/\(tag)")
            if let sha = c["sha"]?.string {
                return .init(sha: sha, source: .release, tag: tag, date: HTTP.date(rel["published_at"]?.string), message: rel["name"]?.string ?? tag)
            }
        }
        let list = try await getJSON("/repos/\(repo)/commits?per_page=1")
        guard let c = list[0], let sha = c["sha"]?.string else { throw SecurityCageError.installFailed("Could not read \(repo) from GitHub") }
        return .init(sha: sha, source: .head, tag: nil, date: HTTP.date(c["commit"]?["committer"]?["date"]?.string),
                     message: (c["commit"]?["message"]?.string ?? "").components(separatedBy: "\n").first ?? "")
    }

    public func checkForUpdate() async throws -> SecurityCageUpdate? {
        guard let p = pin() else { return nil }
        let remote = try await latestRemote()
        guard remote.sha != p.sha else { return nil }
        let cmp = try await getJSON("/repos/\(repo)/compare/\(p.sha)...\(remote.sha)")
        let ahead = cmp["ahead_by"]?.int ?? 1
        let heads = (cmp["commits"]?.array ?? []).reversed().prefix(5).compactMap { ($0["commit"]?["message"]?.string)?.components(separatedBy: "\n").first }
        return SecurityCageUpdate(remote: remote, commitsBehind: ahead, headlines: Array(heads))
    }

    // MARK: Install / update / rollback

    /// Installs at `sha` (default: latest). `progress` receives plain-language step names.
    @discardableResult
    public func install(sha requested: String? = nil, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SecurityCagePin {
        let st = await status()
        if let problem = st.problem { throw SecurityCageError.unavailable(problem) }
        progress("Finding the latest version")
        let sha: String
        if let r = requested { sha = r } else { sha = try await latestRemote().sha }
        let fm = FileManager.default
        let finalDir = root.appendingPathComponent(String(sha.prefix(12)))
        if fm.fileExists(atPath: finalDir.appendingPathComponent("committo-pin.json").path) {
            try activate(finalDir); return pin()!
        }
        let tmp = root.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        progress("Downloading")
        guard let url = URL(string: "\(codeload)/\(repo)/tar.gz/\(sha)") else { throw SecurityCageError.installFailed("Bad URL") }
        var req = URLRequest(url: url); req.setValue("Committo", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw SecurityCageError.installFailed("Download failed (HTTP \(h.statusCode))") }
        let tgz = tmp.appendingPathComponent("src.tgz"); try data.write(to: tgz)

        progress("Verifying")
        let digest = try await Self.sha256(of: tgz)
        let src = tmp.appendingPathComponent("src"); try fm.createDirectory(at: src, withIntermediateDirectories: true)
        _ = try await Shell.check("tar", ["-xzf", tgz.path, "-C", src.path, "--strip-components=1"])
        guard fm.fileExists(atPath: src.appendingPathComponent("packages/cli/src/cli.ts").path) else {
            throw SecurityCageError.installFailed("Downloaded archive does not look like SecurityCage")
        }

        progress("Installing dependencies")
        _ = try await Shell.check("npm", ["ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund"], cwd: src)

        progress("Self-test on a known-bad sample")
        try await selfTest(cliPath: src.appendingPathComponent("packages/cli/src/cli.ts"), scratch: tmp)

        let version = (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: src.appendingPathComponent("packages/cli/package.json"))))?["version"]?.string ?? "0"
        let pin = SecurityCagePin(repo: repo, sha: sha, version: version, installedAt: Date(), tarballSHA256: digest, node: st.node ?? "")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(pin).write(to: src.appendingPathComponent("committo-pin.json"))

        progress("Activating")
        if fm.fileExists(atPath: finalDir.path) { try fm.removeItem(at: finalDir) }
        try fm.moveItem(at: src, to: finalDir)
        let previous = pin_target()
        try activate(finalDir)
        prune(keep: [finalDir.lastPathComponent, previous?.lastPathComponent].compactMap { $0 })
        return pin
    }

    /// Update = install latest. The old pin stays on disk until the next update, so `rollback()` works.
    public func update(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SecurityCagePin { try await install(progress: progress) }

    public func rollback() throws {
        let fm = FileManager.default
        let cur = pin_target()?.lastPathComponent
        let dirs = (try fm.contentsOfDirectory(atPath: root.path)).filter { $0 != cur && $0 != "current" && !$0.hasPrefix(".") && fm.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("committo-pin.json").path) }
        guard let prev = dirs.sorted(by: { mtime($0) > mtime($1) }).first else { throw SecurityCageError.unavailable("No previous version to roll back to") }
        try activate(root.appendingPathComponent(prev))
    }

    public func uninstall() throws {
        for item in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] { try? FileManager.default.removeItem(at: root.appendingPathComponent(item)) }
    }

    func mtime(_ name: String) -> Date { (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? .distantPast }
    func pin_target() -> URL? { (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)).map { root.appendingPathComponent($0) } }
    func activate(_ dir: URL) throws {
        let fm = FileManager.default
        let tmpLink = root.appendingPathComponent(".current-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: tmpLink.path, withDestinationPath: dir.lastPathComponent)
        // rename(2) atomically replaces an existing symlink; FileManager.moveItem does not do this reliably.
        guard rename(tmpLink.path, current.path) == 0 else {
            try? fm.removeItem(at: tmpLink)
            throw SecurityCageError.installFailed("Could not activate the new version (errno \(errno))")
        }
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
    }
    func prune(keep: [String]) {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !n.hasPrefix(".") && n != "current" && n != "state" && n != "results" && !keep.contains(n) {
            try? fm.removeItem(at: root.appendingPathComponent(n))
        }
    }

    static func sha256(of file: URL) async throws -> String {
        for tool in [("shasum", ["-a", "256"]), ("sha256sum", [])] where Shell.which(tool.0) != nil {
            let out = try await Shell.check(tool.0, tool.1 + [file.path])
            return String(out.split(separator: " ").first ?? "")
        }
        throw SecurityCageError.installFailed("No SHA-256 tool found")
    }

    static let fixtureRoute = "import { db } from \"@/db\";\nexport async function POST(req: Request) {\n  const body = await req.json();\n  await db.feedback.create({ data: body });\n  return Response.json({ ok: true });\n}\n"

    /// A tool that cannot find a plainly unguarded endpoint is not safe to trust, so refuse to activate it.
    func selfTest(cliPath: URL, scratch: URL) async throws {
        let fx = scratch.appendingPathComponent("fixture")
        let dir = fx.appendingPathComponent("src/app/api/feedback")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.fixtureRoute.write(to: dir.appendingPathComponent("route.ts"), atomically: true, encoding: .utf8)
        try "{\"name\":\"fixture\",\"dependencies\":{\"next\":\"15.0.0\"}}".write(to: fx.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let r = try await Shell.run("node", [cliPath.path, "plan", fx.path, "--json", "--untrusted", "--no-rules", "--out", scratch.appendingPathComponent("selftest-out").path],
                                    env: ["SECURITYCAGE_STATE_DIR": stateDir.path])
        guard let j = JSONValue.parse(r.stdout), (j["signals"]?.array?.count ?? 0) > 0 else {
            throw SecurityCageError.installFailed("Self-test failed: the new version did not flag a known-bad sample. Not activated.")
        }
    }

    // MARK: Scan

    /// Free offline plan. For pull requests pass the changed paths and `untrusted: true` so the PR cannot vouch for itself.
    public func plan(repo path: URL, changed: [String]? = nil, untrusted: Bool = true, sarif: URL? = nil) async throws -> SecurityCageResult {
        guard pin() != nil, FileManager.default.fileExists(atPath: cli.path) else { throw SecurityCageError.unavailable("SecurityCage is not installed") }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let out = cacheDir.appendingPathComponent(path.path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined())
        var args = [cli.path, "plan", path.path, "--json", untrusted ? "--untrusted" : "--trust-repo-config", "--out", out.path]
        if let changed {
            let f = cacheDir.appendingPathComponent("changed-\(UUID().uuidString).txt")
            try changed.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
            args += ["--changed", f.path]
        }
        if let sarif { args += ["--sarif", sarif.path] }
        let r = try await Shell.run("node", args, env: ["SECURITYCAGE_STATE_DIR": stateDir.path])
        guard let j = JSONValue.parse(r.stdout) else {
            throw SecurityCageError.scanFailed(r.stderr.isEmpty ? "SecurityCage produced no output (exit \(r.status))" : String(r.stderr.prefix(400)))
        }
        return Self.parse(j, outDir: out.path)
    }

    static func parse(_ j: JSONValue, outDir: String) -> SecurityCageResult {
        func sev(_ s: String?) -> Severity { switch s { case "critical": .critical; case "high": .high; case "medium": .medium; case "low": .low; default: .info } }
        var findings: [Finding] = []
        for s in j["signals"]?.array ?? [] {
            let locs = s["locations"]?.array ?? []
            let files = locs.isEmpty ? [JSONValue.object([:])] : locs
            for l in files {
                var f = Finding(rule: "securitycage." + (s["check"]?.string ?? s["id"]?.string ?? "item"), title: s["what"]?.string ?? "Security item",
                                severity: sev(s["severity"]?.string), file: l["path"]?.string ?? "", line: l["line"]?.int ?? 1,
                                snippet: s["why"]?.string ?? "", advice: s["action"]?.string ?? "")
                f.certainty = s["certainty"]?.string; f.fixPrompt = s["fixPrompt"]?.string; f.source = "securitycage"
                findings.append(f)
            }
        }
        findings.sort { ($0.severity, $0.certainty == "confirmed" ? 1 : 0) > ($1.severity, $1.certainty == "confirmed" ? 1 : 0) }
        let est = j["estimate"]
        let range: ClosedRange<Double>? = (est?["lowUsd"]?.double).flatMap { lo in (est?["highUsd"]?.double).map { lo...max(lo, $0) } }
        return SecurityCageResult(findings: findings, surfaces: j["surfaces"]?.int ?? 0, estimateUSD: range, rulesRan: j["rules"]?["ran"]?.bool ?? false,
                                  notes: (j["notices"]?.array ?? []).compactMap(\.string), outDir: outDir,
                                  changedSurfaces: (j["changes"]?["surfaces"]?.array ?? []).compactMap(\.string))
    }

    /// Workflow that runs SecurityCage on pull requests, pinned to a commit SHA (never a moving tag).
    public static func workflowYAML(sha: String, repo: String = "kalahroudi/securitycage") -> String {
        """
        name: securitycage
        on: pull_request   # the PR's code is scanned as data and never run
        permissions:
          contents: read
          pull-requests: write
          security-events: write
        jobs:
          scan:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v4
              - uses: \(repo)@\(sha)
                with:
                  fail-on: high
        """
    }
}
