import Foundation
#if canImport(Network)
import Network

/// LAN CI runner: `committo ci-serve --port 7771 --token <secret>`.
/// Advertises `_committo-ci._tcp` over Bonjour. API (all require `Authorization: Bearer <token>`):
///   GET  /v1/health
///   GET  /v1/workflows?repo=<remote-url>          -> [Workflow]
///   POST /v1/runs   {request, ref}                -> streamed text/plain log, last line `::committo-exit::<code>`
/// The server shallow-clones the remote into a cache dir, checks out `ref`, then runs `act`.
public final class CIServer: @unchecked Sendable {
    let port: NWEndpoint.Port, token: String, cacheDir: URL
    var listener: NWListener?
    let queue = DispatchQueue(label: "committo.ci-server")

    public init(port: UInt16 = 7771, token: String, cacheDir: URL = RepoStore.supportDirectory.appendingPathComponent("ci-cache")) {
        self.port = NWEndpoint.Port(rawValue: port)!; self.token = token; self.cacheDir = cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    public func start(advertise: Bool = true) throws {
        let l = try NWListener(using: .tcp, on: port)
        if advertise { l.service = NWListener.Service(name: Host.current().localizedName ?? "Committo CI", type: "_committo-ci._tcp") }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: queue)
        listener = l
    }
    public func stop() { listener?.cancel() }

    func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }
    func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer; if let data { buf.append(data) }
            if let req = HTTPRequest(buf) { Task { await self.route(req, c) } }
            else if done || err != nil || buf.count > 8 << 20 { c.cancel() }
            else { self.receive(c, buffer: buf) }
        }
    }
    func send(_ c: NWConnection, status: Int, body: Data, type: String = "application/json") {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
    func sendChunk(_ c: NWConnection, _ s: String) {
        let d = Data(s.utf8); c.send(content: Data("\(String(d.count, radix: 16))\r\n".utf8) + d + Data("\r\n".utf8), completion: .idempotent)
    }

    func route(_ r: HTTPRequest, _ c: NWConnection) async {
        guard r.headers["authorization"] == "Bearer \(token)" else { return send(c, status: 401, body: Data("{\"message\":\"unauthorized\"}".utf8)) }
        switch (r.method, r.path) {
        case ("GET", "/v1/health"): send(c, status: 200, body: Data("{\"ok\":true,\"act\":\(ActRunner.isInstalled)}".utf8))
        case ("GET", "/v1/workflows"):
            guard let repo = r.query["repo"], let dir = try? await checkout(repo, ref: nil, log: { _ in }) else { return send(c, status: 400, body: Data("[]".utf8)) }
            let wf = (try? await ActRunner().workflows(in: dir)) ?? []
            send(c, status: 200, body: (try? JSONEncoder().encode(wf)) ?? Data("[]".utf8))
        case ("POST", "/v1/runs"):
            guard let run = try? JSONDecoder().decode(RemoteRun.self, from: r.body) else { return send(c, status: 400, body: Data("{}".utf8)) }
            c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8), completion: .idempotent)
            var code = 1
            do {
                let dir = try await checkout(run.request.repoPath, ref: run.ref) { self.sendChunk(c, $0 + "\n") }
                var req = run.request; req.repoPath = dir.path
                var ok = false
                for try await e in ActRunner().run(req) { switch e { case .log(let l): sendChunk(c, l + "\n"); case .finished(let s): ok = s } }
                code = ok ? 0 : 1
            } catch { sendChunk(c, "runner error: \(error.localizedDescription)\n") }
            sendChunk(c, "::committo-exit::\(code)\n")
            c.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
        default: send(c, status: 404, body: Data("{}".utf8))
        }
    }

    func checkout(_ remote: String, ref: String?, log: @escaping (String) -> Void) async throws -> URL {
        // Only https/ssh remotes: never let a client point the runner at a local path.
        guard remote.hasPrefix("https://") || remote.hasPrefix("git@") || remote.hasPrefix("ssh://") else { throw ProviderError(message: "Unsupported remote") }
        let key = remote.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        let dir = cacheDir.appendingPathComponent(key)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            log("cloning \(remote)")
            _ = try await Shell.check("git", ["clone", "--depth", "50", "--", remote, dir.path])
        }
        _ = try await Shell.check("git", ["fetch", "--depth", "50", "origin"] + (ref.map { [$0] } ?? []), cwd: dir)
        if let ref { _ = try await Shell.check("git", ["checkout", "-f", "FETCH_HEAD"], cwd: dir); log("checked out \(ref)") }
        else { _ = try await Shell.check("git", ["checkout", "-f", "FETCH_HEAD"], cwd: dir) }
        return dir
    }
}

struct HTTPRequest {
    let method: String, path: String, query: [String: String], headers: [String: String], body: Data
    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)), let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var h: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let len = Int(h["content-length"] ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= len else { return nil }
        method = String(first[0])
        let comps = URLComponents(string: String(first[1]))
        path = comps?.path ?? String(first[1])
        query = Dictionary((comps?.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        headers = h; self.body = Data(body.prefix(len))
    }
}

/// Finds CI runners on the local network.
public final class CIDiscovery: @unchecked Sendable {
    public struct Found: Identifiable, Hashable, Sendable { public var id: String { name }; public let name: String; public let endpoint: NWEndpoint }
    private var browser: NWBrowser?
    public init() {}
    public func start(_ onChange: @escaping @Sendable ([Found]) -> Void) {
        let b = NWBrowser(for: .bonjour(type: "_committo-ci._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            onChange(results.compactMap { r in if case let .service(name, _, _, _) = r.endpoint { return Found(name: name, endpoint: r.endpoint) }; return nil })
        }
        b.start(queue: .main); browser = b
    }
    public func stop() { browser?.cancel() }
}
#endif
