import Foundation

public enum SignatureStatus: String, Sendable, Hashable {
    case valid = "G", bad = "B", unknownKey = "U", expired = "X", expiredKey = "Y", revoked = "R", cannotCheck = "E", unsigned = "N"
    public var isSigned: Bool { self != .unsigned }
    /// Shown as the green "verified" badge.
    public var isVerified: Bool { self == .valid }
}

public struct SignatureInfo: Sendable, Hashable {
    public let status: SignatureStatus
    /// Principal from the allowed-signers file (SSH) or the user id (GPG).
    public let signer: String?
    public let key: String?
}

public struct SigningSetup: Sendable, Equatable {
    /// `ssh`, `openpgp` or `x509` (git's `gpg.format`; `openpgp` when unset).
    public var format = "openpgp"
    public var key: String?
    public var signCommits = false
    public var signTags = false
    public var allowedSignersFile: String?
    public var isConfigured: Bool { signCommits && key?.isEmpty == false }
    public init() {}
}

public struct SSHKey: Identifiable, Hashable, Sendable {
    public var id: String { publicKeyPath.path }
    public let privateKeyPath: URL
    public let publicKeyPath: URL
    public let type: String           // ssh-ed25519, ecdsa-sha2-nistp256, ssh-rsa ...
    public let publicKey: String      // "ssh-ed25519 AAAA… comment"
    public let comment: String
    public var fingerprintBlob: String { publicKey.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
}

public struct SigningError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public enum SigningScope: Sendable {
    case global
    case local(GitRepository)
}

/// Commit signing setup (SPEC §9): find or generate an SSH key, write git's signing config, maintain the allowed-signers
/// file that makes SSH signatures verifiable, and read back per-commit verification.
/// `env` lets tests redirect git's global config (`GIT_CONFIG_GLOBAL`, `HOME`).
public enum Signing {
    public static var defaultSSHDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh") }
    public static var defaultGlobalAllowedSigners: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/git/allowed_signers")
    }

    // MARK: Reading

    /// Effective signing configuration: for a repo this resolves local over global like git itself.
    public static func current(in repo: GitRepository? = nil, env: [String: String] = [:]) async -> SigningSetup {
        func get(_ key: String) async -> String? {
            var args = ["config"]
            if repo == nil { args.append("--global") }
            args += ["--get", key]
            guard let r = try? await Shell.run("git", args, cwd: repo?.url, env: env), r.ok else { return nil }
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        func flag(_ key: String) async -> Bool { await get(key)?.lowercased() == "true" }
        var s = SigningSetup()
        s.format = await get("gpg.format") ?? "openpgp"
        s.key = await get("user.signingkey")
        s.signCommits = await flag("commit.gpgsign")
        s.signTags = await flag("tag.gpgsign")
        s.allowedSignersFile = await get("gpg.ssh.allowedSignersFile")
        return s
    }

    /// SSH public keys found in `directory` (default `~/.ssh`).
    public static func sshKeys(in directory: URL = defaultSSHDirectory) -> [SSHKey] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "pub" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { pub in
            guard let line = (try? String(contentsOf: pub, encoding: .utf8))?.split(separator: "\n").first.map(String.init) else { return nil }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, parts[0].hasPrefix("ssh-") || parts[0].hasPrefix("ecdsa-") || parts[0].hasPrefix("sk-") else { return nil }
            let priv = pub.deletingPathExtension()
            guard FileManager.default.fileExists(atPath: priv.path) else { return nil }
            return SSHKey(privateKeyPath: priv, publicKeyPath: pub, type: parts[0], publicKey: line, comment: parts.count > 2 ? parts[2] : "")
        }
    }

    // MARK: Generating and configuring

    /// Creates an ed25519 key pair at `url` (private) and `url.pub`. Refuses to overwrite an existing key.
    /// A passphrase passed here is visible to local processes in the argument list while `ssh-keygen` runs; prefer an empty
    /// passphrase plus the macOS Keychain/agent, or generate in Terminal if that matters.
    public static func generateKey(at url: URL, comment: String, passphrase: String = "") async throws -> SSHKey {
        guard Shell.which("ssh-keygen") != nil else { throw SigningError(message: "ssh-keygen was not found") }
        let pub = URL(fileURLWithPath: url.path + ".pub")
        guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: pub.path) else {
            throw SigningError(message: "A key already exists at \(url.path)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = try await Shell.check("ssh-keygen", ["-t", "ed25519", "-N", passphrase, "-C", comment, "-f", url.path, "-q"])
        guard let key = sshKeys(in: url.deletingLastPathComponent()).first(where: { $0.privateKeyPath.lastPathComponent == url.lastPathComponent }) else {
            throw SigningError(message: "ssh-keygen did not produce a readable key")
        }
        return key
    }

    /// Writes git's signing configuration for SSH signing and registers the key as an allowed signer for `email`.
    /// For `.local` scope the allowed-signers file lives inside the repo's `.git`; for `.global` it is `allowedSigners`.
    public static func configureSSH(key: SSHKey, email: String, scope: SigningScope, signTags: Bool = false,
                                    allowedSigners: URL? = nil, env: [String: String] = [:]) async throws {
        let file: URL
        var base = ["config"]
        var cwd: URL?
        switch scope {
        case .global:
            file = allowedSigners ?? defaultGlobalAllowedSigners
            base.append("--global")
        case .local(let repo):
            file = allowedSigners ?? repo.url.appendingPathComponent(".git/allowed_signers")
            base.append("--local"); cwd = repo.url
        }
        try addAllowedSigner(file: file, principal: email, publicKey: key.publicKey)
        let settings: [(String, String)] = [
            ("gpg.format", "ssh"), ("user.signingkey", key.publicKeyPath.path), ("commit.gpgsign", "true"),
            ("tag.gpgsign", signTags ? "true" : "false"), ("gpg.ssh.allowedSignersFile", file.path),
        ]
        for (k, v) in settings { _ = try await Shell.check("git", base + [k, v], cwd: cwd, env: env) }
    }

    /// Turns commit signing off without deleting the key or the allowed-signers file.
    public static func disable(scope: SigningScope, env: [String: String] = [:]) async throws {
        var args = ["config"]; var cwd: URL?
        switch scope { case .global: args.append("--global"); case .local(let r): args.append("--local"); cwd = r.url }
        _ = try await Shell.check("git", args + ["commit.gpgsign", "false"], cwd: cwd, env: env)
        _ = try await Shell.check("git", args + ["tag.gpgsign", "false"], cwd: cwd, env: env)
    }

    /// Adds `principal namespaces="git" <key>` unless that principal+key pair is already present. Returns true if the file changed.
    @discardableResult
    public static func addAllowedSigner(file: URL, principal: String, publicKey: String) throws -> Bool {
        let blob = publicKey.split(separator: " ").prefix(2).joined(separator: " ")       // "type base64", comment dropped
        guard !principal.contains(where: \.isWhitespace), !principal.isEmpty else { throw SigningError(message: "Invalid signer email: \(principal)") }
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let already = existing.split(separator: "\n").contains { $0.hasPrefix(principal + " ") && $0.contains(blob) }
        if already { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + sep + "\(principal) namespaces=\"git\" \(blob)\n").write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: Diagnosing

    /// Human-readable problems that would make signed commits fail or show as unverified. Empty means ready.
    public static func diagnose(_ setup: SigningSetup, email: String?) -> [String] {
        var problems: [String] = []
        if !setup.signCommits { problems.append("Commit signing is off (commit.gpgsign is not true).") }
        guard let key = setup.key, !key.isEmpty else { problems.append("No signing key is configured (user.signingkey)."); return problems }
        if setup.format == "ssh" {
            if !key.hasPrefix("ssh-") && !key.hasPrefix("key::") {
                if !FileManager.default.fileExists(atPath: (key as NSString).expandingTildeInPath) { problems.append("The signing key file \(key) does not exist.") }
            }
            if let f = setup.allowedSignersFile {
                if !FileManager.default.fileExists(atPath: (f as NSString).expandingTildeInPath) { problems.append("The allowed-signers file \(f) does not exist, so signatures cannot be verified.") }
                else if let email, let content = try? String(contentsOfFile: (f as NSString).expandingTildeInPath, encoding: .utf8), !content.contains(email) {
                    problems.append("\(email) is not in the allowed-signers file, so your commits will show as unverified.")
                }
            } else { problems.append("gpg.ssh.allowedSignersFile is not set, so signatures cannot be verified locally.") }
        }
        if Shell.which(setup.format == "ssh" ? "ssh-keygen" : "gpg") == nil { problems.append("The \(setup.format == "ssh" ? "ssh-keygen" : "gpg") tool was not found.") }
        return problems
    }
}

extension GitRepository {
    /// Verification status for specific commits (call for the rows on screen, not the whole history: git verifies each
    /// signed commit by running ssh-keygen or gpg). Unsigned commits are reported as `.unsigned`.
    public func signatures(for hashes: [String]) async throws -> [String: SignatureInfo] {
        var out: [String: SignatureInfo] = [:]
        for chunk in stride(from: 0, to: hashes.count, by: 100).map({ Array(hashes[$0..<min($0 + 100, hashes.count)]) }) {
            let args = ["log", "--no-walk=unsorted", "--format=%H%x1f%G?%x1f%GS%x1f%GK%x1e"] + chunk
            for try await rec in gitRecords(args, separator: 0x1E) {
                let f = String(decoding: rec, as: UTF8.self).trimmingCharacters(in: .newlines).components(separatedBy: GitParse.us)
                guard f.count >= 4, f[0].count >= 40 else { continue }
                out[f[0]] = SignatureInfo(status: SignatureStatus(rawValue: f[1]) ?? .cannotCheck,
                                          signer: f[2].isEmpty ? nil : f[2], key: f[3].isEmpty ? nil : f[3])
            }
        }
        return out
    }
}
