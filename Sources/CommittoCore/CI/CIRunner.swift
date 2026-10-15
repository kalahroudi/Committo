import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Workflow: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(file)#\(job)" }
    public let stage: String, job: String, name: String, file: String, events: String
}

public struct CIRunRequest: Codable, Sendable {
    public var repoPath: String          // local runner: working dir
    public var workflowFile: String?
    public var job: String?
    public var event: String = "push"
    public var dryRun = false
    public var secrets: [String: String] = [:]
    public init(repoPath: String, workflowFile: String? = nil, job: String? = nil, event: String = "push", dryRun: Bool = false) {
        self.repoPath = repoPath; self.workflowFile = workflowFile; self.job = job; self.event = event; self.dryRun = dryRun
    }
}

public enum CIEvent: Sendable { case log(String), finished(success: Bool) }

public protocol CIRunner: Sendable {
    var name: String { get }
    func workflows(in repo: URL) async throws -> [Workflow]
    func run(_ req: CIRunRequest) -> AsyncThrowingStream<CIEvent, Error>
}

/// Local runner: wraps nektos/act (https://github.com/nektos/act). Requires a Docker-compatible runtime.
public struct ActRunner: CIRunner {
    public let name = "Local (act)"
    public init() {}
    public static var isInstalled: Bool { Shell.which("act") != nil }
    public static var dockerRunning: Bool { Shell.which("docker") != nil && FileManager.default.fileExists(atPath: "/var/run/docker.sock") || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.docker/run/docker.sock") }

    public func workflows(in repo: URL) async throws -> [Workflow] {
        let out = try await Shell.check("act", ["-l"], cwd: repo)
        return Self.parseList(out)
    }
    /// Parses `act -l` table: Stage  Job ID  Job name  Workflow name  Workflow file  Events
    static func parseList(_ out: String) -> [Workflow] {
        let lines = out.split(separator: "\n").map(String.init)
        guard let header = lines.first, header.contains("Job ID") else { return [] }
        func col(_ n: String) -> String.Index? { header.range(of: n)?.lowerBound }
        guard let jobID = col("Job ID"), let jobName = col("Job name"), let wfName = col("Workflow name"), let wfFile = col("Workflow file"), let ev = col("Events") else { return [] }
        let off = { (i: String.Index) in header.distance(from: header.startIndex, to: i) }
        func slice(_ l: String, _ a: Int, _ b: Int?) -> String {
            guard l.count > a else { return "" }
            let s = l.index(l.startIndex, offsetBy: a); let e = b.map { l.index(l.startIndex, offsetBy: min($0, l.count)) } ?? l.endIndex
            return String(l[s..<e]).trimmingCharacters(in: .whitespaces)
        }
        return lines.dropFirst().compactMap { l in
            let job = slice(l, off(jobID), off(jobName)); guard !job.isEmpty else { return nil }
            return Workflow(stage: slice(l, 0, off(jobID)), job: job, name: slice(l, off(wfName), off(wfFile)), file: slice(l, off(wfFile), off(ev)), events: slice(l, off(ev), nil))
        }
    }

    public func run(_ req: CIRunRequest) -> AsyncThrowingStream<CIEvent, Error> {
        var args = [req.event]
        if let f = req.workflowFile { args += ["-W", ".github/workflows/\(f)"] }
        if let j = req.job { args += ["-j", j] }
        if req.dryRun { args.append("-n") }
        // Apple Silicon: act's images are amd64.
        #if arch(arm64)
        args += ["--container-architecture", "linux/amd64"]
        #endif
        for (k, _) in req.secrets { args += ["-s", k] }     // value comes from env, never argv
        let lines = Shell.stream("act", args, cwd: URL(fileURLWithPath: req.repoPath), env: req.secrets)
        return AsyncThrowingStream { cont in
            let t = Task {
                do { for try await l in lines { cont.yield(.log(l)) }; cont.yield(.finished(success: true)); cont.finish() }
                catch { cont.yield(.finished(success: false)); cont.finish() }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

/// Runs CI on another machine on your LAN that is running `committo ci-serve`.
public struct RemoteCIRunner: CIRunner {
    public let name: String
    public let baseURL: URL
    public let token: String
    public init(name: String, baseURL: URL, token: String) { self.name = name; self.baseURL = baseURL; self.token = token }

    func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path)); r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.timeoutInterval = 3600
        return r
    }
    public func health() async -> Bool { (try? await URLSession.shared.data(for: request("v1/health")))?.1 is HTTPURLResponse }

    public func workflows(in repo: URL) async throws -> [Workflow] {
        guard let remote = await GitRepository(url: repo).remoteURL() else { throw ProviderError(message: "Repo has no origin remote") }
        var c = URLComponents(url: baseURL.appendingPathComponent("v1/workflows"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "repo", value: remote)]
        var r = request("v1/workflows"); r.url = c.url
        let (d, _) = try await URLSession.shared.data(for: r)
        return try JSONDecoder().decode([Workflow].self, from: d)
    }
    /// `req.repoPath` is interpreted on the server as a git remote URL; the client sends origin + current ref.
    /// Unpushed work: push a WIP branch first (the UI offers "Push & run").
    public func run(_ req: CIRunRequest) -> AsyncThrowingStream<CIEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    let repo = GitRepository(url: URL(fileURLWithPath: req.repoPath))
                    guard let remote = await repo.remoteURL() else { throw ProviderError(message: "Repo has no origin remote") }
                    let ref = try await repo.currentBranch()
                    var wire = req; wire.repoPath = remote; wire.secrets = [:]
                    let body = try JSONEncoder().encode(RemoteRun(request: wire, ref: ref))
                    var ok = false
                    func handle(_ line: String) { if line.hasPrefix("::committo-exit::") { ok = line.hasSuffix("0") } else { cont.yield(.log(line)) } }
                    #if canImport(FoundationNetworking)
                    let (data, resp) = try await URLSession.shared.data(for: request("v1/runs", method: "POST", body: body))   // no live streaming on Linux
                    if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ProviderError(message: "Runner replied HTTP \(h.statusCode)") }
                    String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).forEach { handle(String($0)) }
                    #else
                    let (bytes, resp) = try await URLSession.shared.bytes(for: request("v1/runs", method: "POST", body: body))
                    if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ProviderError(message: "Runner replied HTTP \(h.statusCode)") }
                    for try await line in bytes.lines { handle(line) }
                    #endif
                    cont.yield(.finished(success: ok)); cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

struct RemoteRun: Codable { var request: CIRunRequest; var ref: String }

public struct CIServerConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String { url }
    public var name: String
    public var url: String
    public var keychainAccount: String { "ci.\(url)" }
    public init(name: String, url: String) { self.name = name; self.url = url }
    public func runner() -> RemoteCIRunner? { URL(string: url).map { RemoteCIRunner(name: name, baseURL: $0, token: Keychain.get(keychainAccount) ?? "") } }
}
