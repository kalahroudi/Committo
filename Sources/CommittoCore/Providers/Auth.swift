import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// `gh` CLI integration: reuse an existing login or drive `gh auth login --web`.
public enum GitHubCLI {
    public static var isInstalled: Bool { Shell.which("gh") != nil }
    public static func token(host: String = "github.com") async -> String? {
        guard let r = try? await Shell.run("gh", ["auth", "token", "-h", host]), r.ok else { return nil }
        let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    public static func username(host: String = "github.com") async -> String? {
        guard let r = try? await Shell.run("gh", ["api", "user", "--hostname", host, "-q", ".login"]), r.ok else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Streams the interactive device-code output (contains the one-time code to show in the UI).
    public static func loginWeb(host: String = "github.com") -> AsyncThrowingStream<String, Error> {
        Shell.stream("gh", ["auth", "login", "--web", "-h", host, "-p", "https", "--git-protocol", "https", "--scopes", "repo,read:org,workflow"], stdin: "\n")
    }
    /// Make `git push/pull` use gh credentials for https remotes.
    public static func setupGit() async { _ = try? await Shell.run("gh", ["auth", "setup-git"]) }
}

public struct DeviceCode: Sendable { public let userCode: String; public let verificationURL: URL; public let deviceCode: String; public let interval: Int; public let expiresIn: Int }

/// OAuth 2.0 Device Authorization Grant (RFC 8628). Works for GitHub and GitLab with no client secret and
/// no redirect URI, so Committo ships no embedded credentials: supply your own OAuth app client id in Settings.
public struct DeviceFlow: Sendable {
    public let provider: ProviderKind, host: String, clientID: String, scopes: String
    public init(provider: ProviderKind, host: String? = nil, clientID: String, scopes: String? = nil) {
        self.provider = provider; self.host = host ?? provider.defaultHost; self.clientID = clientID
        self.scopes = scopes ?? (provider == .github ? "repo read:org workflow" : "api read_user")
    }
    var codeURL: URL { URL(string: provider == .github ? "https://\(host)/login/device/code" : "https://\(host)/oauth/authorize_device")! }
    var tokenURL: URL { URL(string: provider == .github ? "https://\(host)/login/oauth/access_token" : "https://\(host)/oauth/token")! }

    func post(_ url: URL, _ form: [String: String]) async throws -> JSONValue {
        var r = URLRequest(url: url); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (d, _) = try await URLSession.shared.data(for: r)
        return try JSONDecoder().decode(JSONValue.self, from: d)
    }
    public func start() async throws -> DeviceCode {
        let j = try await post(codeURL, ["client_id": clientID, "scope": scopes])
        guard let uc = j["user_code"]?.string, let dc = j["device_code"]?.string,
              let vu = (j["verification_uri_complete"]?.string ?? j["verification_uri"]?.string).flatMap(URL.init) else {
            throw NSError(domain: "DeviceFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: j["error_description"]?.string ?? "Device flow unavailable for this OAuth app"])
        }
        return DeviceCode(userCode: uc, verificationURL: vu, deviceCode: dc, interval: j["interval"]?.int ?? 5, expiresIn: j["expires_in"]?.int ?? 900)
    }
    public func poll(_ code: DeviceCode) async throws -> String {
        var interval = code.interval
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let j = try await post(tokenURL, ["client_id": clientID, "device_code": code.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            if let t = j["access_token"]?.string { return t }
            switch j["error"]?.string {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            default: throw NSError(domain: "DeviceFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: j["error_description"]?.string ?? "Authorization failed"])
            }
        }
        throw NSError(domain: "DeviceFlow", code: 3, userInfo: [NSLocalizedDescriptionKey: "Code expired"])
    }
}

/// Authorization-code + PKCE for providers without device flow (Bitbucket, Azure DevOps, Gitea).
/// The app target runs this through ASWebAuthenticationSession (`committo://oauth`).
#if canImport(CryptoKit)
public struct PKCE: Sendable {
    public let verifier: String, challenge: String
    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        verifier = Data(bytes).base64URL
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
    public func authorizeURL(base: URL, clientID: String, redirect: String, scope: String, state: String) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: redirect),
                        .init(name: "scope", value: scope), .init(name: "state", value: state), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")]
        return c.url!
    }
}
extension Data { var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
#endif
