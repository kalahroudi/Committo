import Foundation

public enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case github, gitlab, bitbucket, azureDevOps, gitea
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .github: "GitHub"; case .gitlab: "GitLab"; case .bitbucket: "Bitbucket"; case .azureDevOps: "Azure DevOps"; case .gitea: "Gitea / Forgejo" }
    }
    public var defaultHost: String {
        switch self { case .github: "github.com"; case .gitlab: "gitlab.com"; case .bitbucket: "bitbucket.org"; case .azureDevOps: "dev.azure.com"; case .gitea: "codeberg.org" }
    }
    public var symbol: String {
        switch self { case .github: "cat.fill"; case .gitlab: "fox.fill"; case .bitbucket: "bucket.fill"; case .azureDevOps: "cloud.fill"; case .gitea: "leaf.fill" }
    }
    public var tokenHelpURL: String {
        switch self {
        case .github: "https://github.com/settings/tokens/new?scopes=repo,read:org,workflow"
        case .gitlab: "https://gitlab.com/-/user_settings/personal_access_tokens"
        case .bitbucket: "https://bitbucket.org/account/settings/app-passwords/"
        case .azureDevOps: "https://dev.azure.com/_usersSettings/tokens"
        case .gitea: "https://codeberg.org/user/settings/applications"
        }
    }
    /// Providers whose pull-request APIs are implemented in this build.
    public var supportsPullRequests: Bool { self == .github || self == .gitlab || self == .gitea }
    public var supportsDeviceFlow: Bool { self == .github || self == .gitlab }
}

public enum AuthMethod: String, Codable, Sendable { case oauth, token, ghCLI }

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(provider.rawValue)@\(host)/\(username)" }
    public let provider: ProviderKind
    public let host: String
    public var username: String
    public var method: AuthMethod
    public var avatarURL: String?
    public var keychainKey: String { id }
}

public final class AccountStore: @unchecked Sendable {
    public static let shared = AccountStore()
    private let file = RepoStore.supportDirectory.appendingPathComponent("accounts.json")
    private let lock = NSLock()
    private var accounts: [Account] = []
    public init() { if let d = try? Data(contentsOf: file), let a = try? JSONDecoder().decode([Account].self, from: d) { accounts = a } }

    public func all() -> [Account] { lock.lock(); defer { lock.unlock() }; return accounts }
    public func add(_ a: Account, token: String) {
        lock.lock(); defer { lock.unlock() }
        accounts.removeAll { $0.id == a.id }; accounts.append(a)
        Keychain.set(token, for: a.keychainKey)
        try? JSONEncoder().encode(accounts).write(to: file, options: .atomic)
    }
    public func remove(_ a: Account) {
        lock.lock(); defer { lock.unlock() }
        accounts.removeAll { $0.id == a.id }; Keychain.delete(a.keychainKey)
        try? JSONEncoder().encode(accounts).write(to: file, options: .atomic)
    }
    public func token(for a: Account) -> String? {
        if a.method == .ghCLI { return nil }   // fetched live from `gh auth token`
        return Keychain.get(a.keychainKey)
    }
    public func resolveToken(for a: Account) async -> String? {
        a.method == .ghCLI ? await GitHubCLI.token(host: a.host) : token(for: a)
    }
}
