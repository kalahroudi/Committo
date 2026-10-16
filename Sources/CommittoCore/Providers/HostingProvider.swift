import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RemoteRepo: Identifiable, Hashable, Sendable {
    public var id: String { fullName }
    public let fullName: String, cloneURL: String, htmlURL: String, description: String?, isPrivate: Bool, updatedAt: Date, language: String?, stars: Int
}
public struct CheckRun: Hashable, Sendable { public let name: String; public let status: String; public let conclusion: String? ; public let url: String? }
public struct PullRequest: Identifiable, Hashable, Sendable {
    public var id: String { "\(repo)#\(number)" }
    public let repo: String, number: Int, title: String, body: String, author: String, headRef: String, baseRef: String, headSHA: String
    public let url: String, isDraft: Bool, updatedAt: Date, additions: Int, deletions: Int, changedFiles: Int, comments: Int, state: String
}
public struct PRFile: Identifiable, Hashable, Sendable { public var id: String { filename }; public let filename: String, status: String, additions: Int, deletions: Int, patch: String? }

public protocol HostingProvider: Sendable {
    var kind: ProviderKind { get }
    func currentUser() async throws -> String
    func repositories(limit: Int) async throws -> [RemoteRepo]
    func pullRequests(repo: String, state: String) async throws -> [PullRequest]
    func pullRequest(repo: String, number: Int) async throws -> PullRequest
    func files(repo: String, number: Int) async throws -> [PRFile]
    func checks(repo: String, sha: String) async throws -> [CheckRun]
    func comment(repo: String, number: Int, body: String) async throws
    func createPullRequest(repo: String, title: String, body: String, head: String, base: String, draft: Bool) async throws -> PullRequest
    func merge(repo: String, number: Int, method: String) async throws
}

public struct ProviderError: LocalizedError, Sendable { public let message: String; public var errorDescription: String? { message } }

enum HTTP {
    // ISO8601DateFormatter is thread-safe for date(from:) and is never reconfigured after init.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    nonisolated(unsafe) static let iso2 = ISO8601DateFormatter()
    static func date(_ s: String?) -> Date { s.flatMap { iso.date(from: $0) ?? iso2.date(from: $0) } ?? Date() }
    static func json(_ req: URLRequest) async throws -> JSONValue {
        let (d, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let msg = (try? JSONDecoder().decode(JSONValue.self, from: d))?["message"]?.string ?? "HTTP \(h.statusCode)"
            throw ProviderError(message: msg)
        }
        return d.isEmpty ? .null : try JSONDecoder().decode(JSONValue.self, from: d)
    }
}

public enum Providers {
    public static func make(for account: Account, token: String) -> HostingProvider? {
        switch account.provider {
        case .github: GitHubProvider(host: account.host, token: token)
        case .gitlab: GitLabProvider(host: account.host, token: token)
        default: nil   // Bitbucket / Azure DevOps / Gitea: auth + clone supported; PR API on the roadmap
        }
    }
}

public struct GitHubProvider: HostingProvider {
    public let kind = ProviderKind.github
    let host: String, token: String
    public init(host: String = "github.com", token: String) { self.host = host; self.token = token }
    var api: String { host == "github.com" ? "https://api.github.com" : "https://\(host)/api/v3" }

    func request(_ path: String, method: String = "GET", body: JSONValue? = nil, accept: String = "application/vnd.github+json") -> URLRequest {
        var r = URLRequest(url: URL(string: api + path)!); r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body { r.httpBody = body.serialized().data(using: .utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    func pr(_ j: JSONValue, repo: String) -> PullRequest {
        PullRequest(repo: repo, number: j["number"]?.int ?? 0, title: j["title"]?.string ?? "", body: j["body"]?.string ?? "", author: j["user"]?["login"]?.string ?? "",
                    headRef: j["head"]?["ref"]?.string ?? "", baseRef: j["base"]?["ref"]?.string ?? "", headSHA: j["head"]?["sha"]?.string ?? "",
                    url: j["html_url"]?.string ?? "", isDraft: j["draft"]?.bool ?? false, updatedAt: HTTP.date(j["updated_at"]?.string),
                    additions: j["additions"]?.int ?? 0, deletions: j["deletions"]?.int ?? 0, changedFiles: j["changed_files"]?.int ?? 0,
                    comments: (j["comments"]?.int ?? 0) + (j["review_comments"]?.int ?? 0), state: j["merged"]?.bool == true ? "merged" : (j["state"]?.string ?? "open"))
    }
    public func currentUser() async throws -> String { try await HTTP.json(request("/user"))["login"]?.string ?? "" }
    public func repositories(limit: Int) async throws -> [RemoteRepo] {
        try await HTTP.json(request("/user/repos?sort=pushed&per_page=\(min(limit, 100))")).array?.map {
            RemoteRepo(fullName: $0["full_name"]?.string ?? "", cloneURL: $0["clone_url"]?.string ?? "", htmlURL: $0["html_url"]?.string ?? "", description: $0["description"]?.string,
                       isPrivate: $0["private"]?.bool ?? false, updatedAt: HTTP.date($0["pushed_at"]?.string), language: $0["language"]?.string, stars: $0["stargazers_count"]?.int ?? 0)
        } ?? []
    }
    public func pullRequests(repo: String, state: String) async throws -> [PullRequest] {
        try await HTTP.json(request("/repos/\(repo)/pulls?state=\(state)&per_page=50")).array?.map { pr($0, repo: repo) } ?? []
    }
    public func pullRequest(repo: String, number: Int) async throws -> PullRequest { pr(try await HTTP.json(request("/repos/\(repo)/pulls/\(number)")), repo: repo) }
    public func files(repo: String, number: Int) async throws -> [PRFile] {
        try await HTTP.json(request("/repos/\(repo)/pulls/\(number)/files?per_page=100")).array?.map {
            PRFile(filename: $0["filename"]?.string ?? "", status: $0["status"]?.string ?? "", additions: $0["additions"]?.int ?? 0, deletions: $0["deletions"]?.int ?? 0, patch: $0["patch"]?.string) } ?? []
    }
    public func checks(repo: String, sha: String) async throws -> [CheckRun] {
        try await HTTP.json(request("/repos/\(repo)/commits/\(sha)/check-runs"))["check_runs"]?.array?.map {
            CheckRun(name: $0["name"]?.string ?? "", status: $0["status"]?.string ?? "", conclusion: $0["conclusion"]?.string, url: $0["html_url"]?.string) } ?? []
    }
    public func comment(repo: String, number: Int, body: String) async throws {
        _ = try await HTTP.json(request("/repos/\(repo)/issues/\(number)/comments", method: "POST", body: ["body": .string(body)]))
    }
    public func createPullRequest(repo: String, title: String, body: String, head: String, base: String, draft: Bool) async throws -> PullRequest {
        pr(try await HTTP.json(request("/repos/\(repo)/pulls", method: "POST", body: ["title": .string(title), "body": .string(body), "head": .string(head), "base": .string(base), "draft": .bool(draft)])), repo: repo)
    }
    public func merge(repo: String, number: Int, method: String) async throws {
        _ = try await HTTP.json(request("/repos/\(repo)/pulls/\(number)/merge", method: "PUT", body: ["merge_method": .string(method)]))
    }
}

public struct GitLabProvider: HostingProvider {
    public let kind = ProviderKind.gitlab
    let host: String, token: String
    public init(host: String = "gitlab.com", token: String) { self.host = host; self.token = token }
    func request(_ path: String, method: String = "GET", body: JSONValue? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://\(host)/api/v4\(path)")!); r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = body.serialized().data(using: .utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    func enc(_ repo: String) -> String { repo.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? repo }
    func mr(_ j: JSONValue, repo: String) -> PullRequest {
        PullRequest(repo: repo, number: j["iid"]?.int ?? 0, title: j["title"]?.string ?? "", body: j["description"]?.string ?? "", author: j["author"]?["username"]?.string ?? "",
                    headRef: j["source_branch"]?.string ?? "", baseRef: j["target_branch"]?.string ?? "", headSHA: j["sha"]?.string ?? "", url: j["web_url"]?.string ?? "",
                    isDraft: j["draft"]?.bool ?? false, updatedAt: HTTP.date(j["updated_at"]?.string), additions: 0, deletions: 0,
                    changedFiles: Int(j["changes_count"]?.string ?? "") ?? 0, comments: j["user_notes_count"]?.int ?? 0, state: j["state"]?.string == "opened" ? "open" : (j["state"]?.string ?? "open"))
    }
    public func currentUser() async throws -> String { try await HTTP.json(request("/user"))["username"]?.string ?? "" }
    public func repositories(limit: Int) async throws -> [RemoteRepo] {
        try await HTTP.json(request("/projects?membership=true&order_by=last_activity_at&per_page=\(min(limit, 100))")).array?.map {
            RemoteRepo(fullName: $0["path_with_namespace"]?.string ?? "", cloneURL: $0["http_url_to_repo"]?.string ?? "", htmlURL: $0["web_url"]?.string ?? "", description: $0["description"]?.string,
                       isPrivate: $0["visibility"]?.string != "public", updatedAt: HTTP.date($0["last_activity_at"]?.string), language: nil, stars: $0["star_count"]?.int ?? 0) } ?? []
    }
    public func pullRequests(repo: String, state: String) async throws -> [PullRequest] {
        try await HTTP.json(request("/projects/\(enc(repo))/merge_requests?state=\(state == "open" ? "opened" : state)&per_page=50")).array?.map { mr($0, repo: repo) } ?? []
    }
    public func pullRequest(repo: String, number: Int) async throws -> PullRequest { mr(try await HTTP.json(request("/projects/\(enc(repo))/merge_requests/\(number)")), repo: repo) }
    public func files(repo: String, number: Int) async throws -> [PRFile] {
        try await HTTP.json(request("/projects/\(enc(repo))/merge_requests/\(number)/changes"))["changes"]?.array?.map {
            let patch = $0["diff"]?.string
            let lines = (patch ?? "").split(separator: "\n")
            return PRFile(filename: $0["new_path"]?.string ?? "", status: $0["new_file"]?.bool == true ? "added" : $0["deleted_file"]?.bool == true ? "removed" : "modified",
                          additions: lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count, deletions: lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count, patch: patch) } ?? []
    }
    public func checks(repo: String, sha: String) async throws -> [CheckRun] {
        try await HTTP.json(request("/projects/\(enc(repo))/repository/commits/\(sha)/statuses")).array?.map {
            CheckRun(name: $0["name"]?.string ?? "", status: "completed", conclusion: $0["status"]?.string == "success" ? "success" : $0["status"]?.string, url: $0["target_url"]?.string) } ?? []
    }
    public func comment(repo: String, number: Int, body: String) async throws {
        _ = try await HTTP.json(request("/projects/\(enc(repo))/merge_requests/\(number)/notes", method: "POST", body: ["body": .string(body)]))
    }
    public func createPullRequest(repo: String, title: String, body: String, head: String, base: String, draft: Bool) async throws -> PullRequest {
        mr(try await HTTP.json(request("/projects/\(enc(repo))/merge_requests", method: "POST", body: ["title": .string(draft ? "Draft: \(title)" : title), "description": .string(body), "source_branch": .string(head), "target_branch": .string(base)])), repo: repo)
    }
    public func merge(repo: String, number: Int, method: String) async throws {
        _ = try await HTTP.json(request("/projects/\(enc(repo))/merge_requests/\(number)/merge", method: "PUT", body: ["squash": .bool(method == "squash")]))
    }
}
