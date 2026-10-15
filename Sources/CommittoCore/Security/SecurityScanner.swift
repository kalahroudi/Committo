import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum Severity: Int, Comparable, Codable, Sendable, CaseIterable {
    case info = 0, low, medium, high, critical
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["Info", "Low", "Medium", "High", "Critical"][rawValue] }
}

public struct Finding: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(rule)|\(file)|\(line)" }
    public let rule: String
    public let title: String
    public let severity: Severity
    public let file: String
    public let line: Int
    public let snippet: String
    public let advice: String
    /// Set by SecurityCage: "confirmed", "likely" or "worth-a-look".
    public var certainty: String? = nil
    /// A prompt the user can hand to an agent to fix the item.
    public var fixPrompt: String? = nil
    public var source: String = "builtin"
}

struct Rule {
    let id: String, title: String, severity: Severity, advice: String
    let regex: NSRegularExpression
    let redact: Bool
    var onlyIn: ((String) -> Bool)? = nil
    init(_ id: String, _ title: String, _ sev: Severity, _ pattern: String, advice: String, redact: Bool = false, onlyIn: ((String) -> Bool)? = nil) {
        self.id = id; self.title = title; self.severity = sev; self.advice = advice; self.redact = redact; self.onlyIn = onlyIn
        self.regex = try! NSRegularExpression(pattern: pattern, options: [])
    }
}

/// Fast, offline diff scanner: secrets, risky code patterns and CI/supply-chain red flags.
/// Only *added* lines are inspected so reviews stay focused on what a PR introduces.
public struct SecurityScanner: Sendable {
    public init() {}

    static let rules: [Rule] = [
        Rule("secret.aws-key", "AWS access key", .critical, #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#, advice: "Rotate the key immediately and load it from the environment or a secret manager.", redact: true),
        Rule("secret.github-token", "GitHub token", .critical, #"\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b"#, advice: "Revoke the token on GitHub and purge it from history.", redact: true),
        Rule("secret.private-key", "Private key material", .critical, #"-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"#, advice: "Remove the key, rotate it, and rewrite history if it was pushed.", redact: true),
        Rule("secret.slack", "Slack token", .high, #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#, advice: "Revoke the Slack token.", redact: true),
        Rule("secret.stripe", "Stripe live key", .critical, #"\b(sk|rk)_live_[A-Za-z0-9]{20,}\b"#, advice: "Roll the Stripe key.", redact: true),
        Rule("secret.google-api", "Google API key", .high, #"\bAIza[0-9A-Za-z_\-]{35}\b"#, advice: "Restrict or rotate the key in Google Cloud.", redact: true),
        Rule("secret.anthropic", "Anthropic API key", .critical, #"\bsk-ant-[A-Za-z0-9_\-]{20,}\b"#, advice: "Revoke the key in the Anthropic console.", redact: true),
        Rule("secret.openai", "OpenAI API key", .critical, #"\bsk-(proj-)?[A-Za-z0-9_\-]{32,}\b"#, advice: "Revoke the key in the OpenAI dashboard.", redact: true),
        Rule("secret.generic", "Hard-coded credential", .medium, #"(?i)\b(password|passwd|secret|api[_-]?key|token)\b\s*[:=]\s*["'][^"'\s]{8,}["']"#, advice: "Move credentials to env vars or the Keychain.", redact: true),
        Rule("code.eval", "Dynamic code execution", .high, #"\b(eval|exec)\s*\("#, advice: "Avoid eval/exec on dynamic input.", onlyIn: { $0.hasSuffix(".py") || $0.hasSuffix(".js") || $0.hasSuffix(".ts") || $0.hasSuffix(".rb") || $0.hasSuffix(".php") }),
        Rule("code.shell-true", "Shell injection risk", .high, #"shell\s*=\s*True|child_process\.exec\(|os\.system\("#, advice: "Pass argv arrays; never interpolate user input into a shell string."),
        Rule("code.sql-concat", "SQL built by concatenation", .high, #"(?i)(SELECT|INSERT|UPDATE|DELETE)\b[^\n]{0,80}["']\s*(\+|%|\.format|\$\{)"#, advice: "Use parameterised queries."),
        Rule("code.tls-off", "TLS verification disabled", .high, #"verify\s*=\s*False|rejectUnauthorized\s*:\s*false|InsecureSkipVerify\s*:\s*true|NSAllowsArbitraryLoads"#, advice: "Keep certificate validation on."),
        Rule("code.innerhtml", "Unsafe HTML injection", .medium, #"\.innerHTML\s*=|dangerouslySetInnerHTML"#, advice: "Sanitise or use text nodes."),
        Rule("code.weak-hash", "Weak hash", .low, #"\b(md5|sha1)\s*\("#, advice: "Use SHA-256+ (and a KDF for passwords)."),
        Rule("code.curl-pipe", "Pipes remote script to shell", .high, #"(curl|wget)[^\n|]*\|\s*(sudo\s+)?(ba|z)?sh"#, advice: "Download, verify a checksum, then execute."),
        Rule("swift.force-try", "Force try / unsafe", .info, #"\btry!\s|\bunsafeBitCast\b"#, advice: "Handle the error or justify the unsafe call.", onlyIn: { $0.hasSuffix(".swift") }),
        Rule("ci.pr-target", "pull_request_target workflow", .high, #"pull_request_target"#, advice: "Never check out untrusted PR code with write tokens in this trigger.", onlyIn: { $0.contains(".github/workflows/") }),
        Rule("ci.unpinned-action", "Action not pinned to a SHA", .low, #"uses:\s*[\w\-./]+@(main|master|v\d+)\s*$"#, advice: "Pin third-party actions to a full commit SHA.", onlyIn: { $0.contains(".github/workflows/") }),
        Rule("ci.script-injection", "Untrusted input in run step", .high, #"\$\{\{\s*github\.(event\.(issue|pull_request|comment|review|head_commit)[\w.]*(title|body|message|ref)|head_ref)\s*\}\}"#, advice: "Pass through an env var instead of interpolating into the script.", onlyIn: { $0.contains(".github/workflows/") }),
        Rule("docker.root", "Container runs as root", .low, #"^USER\s+root\s*$"#, advice: "Drop privileges with a non-root USER.", onlyIn: { $0.hasSuffix("Dockerfile") }),
    ]

    static let sensitiveFiles = [".env", ".env.local", "id_rsa", "id_ed25519", ".npmrc", ".pypirc", "credentials.json", "serviceAccount.json", ".p12", ".pem", ".keystore"]
    static let manifests = ["package.json", "Package.swift", "Podfile", "requirements.txt", "pyproject.toml", "Cargo.toml", "go.mod", "Gemfile", "build.gradle", "pom.xml"]

    public func scan(diff files: [FileDiff]) -> [Finding] {
        var out: [Finding] = []
        for f in files where !f.isBinary {
            let base = (f.path as NSString).lastPathComponent
            if Self.sensitiveFiles.contains(where: { base == $0 || base.hasSuffix($0) }) {
                out.append(.init(rule: "file.sensitive", title: "Sensitive file added", severity: .high, file: f.path, line: 1, snippet: base, advice: "Remove from the repo and add to .gitignore."))
            }
            if Self.manifests.contains(base), f.additions > 0 {
                out.append(.init(rule: "deps.changed", title: "Dependency manifest changed", severity: .info, file: f.path, line: 1, snippet: "\(f.additions) lines added", advice: "Check new packages for typosquatting and known CVEs (OSV)."))
            }
            for h in f.hunks { for l in h.lines where l.kind == .added { out += scanLine(l.text, file: f.path, line: l.newLine ?? 0) } }
        }
        return out.sorted { $0.severity > $1.severity }
    }

    public func scan(files: [(path: String, content: String)]) -> [Finding] {
        files.flatMap { f in f.content.components(separatedBy: "\n").enumerated().flatMap { scanLine($0.element, file: f.path, line: $0.offset + 1) } }
            .sorted { $0.severity > $1.severity }
    }

    func scanLine(_ text: String, file: String, line: Int) -> [Finding] {
        guard text.count < 2000 else { return [] }
        let ns = text as NSString
        var out: [Finding] = []
        for r in Self.rules {
            if let only = r.onlyIn, !only(file) { continue }
            guard let m = r.regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            var snip = ns.substring(with: m.range)
            if r.redact { snip = String(snip.prefix(6)) + "…[redacted]" }
            out.append(.init(rule: r.id, title: r.title, severity: r.severity, file: file, line: line, snippet: snip, advice: r.advice))
        }
        return out
    }

    /// Scan a git working tree: staged + unstaged + untracked changes.
    public func scanWorkingTree(_ repo: GitRepository) async throws -> [Finding] {
        let st = try await repo.status()
        var diffs = try await repo.diff() + (try await repo.diff(staged: true))
        for c in st.changes where c.kind == .untracked { if let d = repo.untrackedContent(c.path) { diffs.append(d) } }
        return scan(diff: diffs)
    }
}

/// Dependency vulnerability lookup via OSV.dev (public, keyless).
public struct OSVClient: Sendable {
    public struct Vuln: Codable, Hashable, Sendable { public let id: String; public let summary: String? }
    public init() {}
    public func query(ecosystem: String, name: String, version: String) async -> [Vuln] {
        var req = URLRequest(url: URL(string: "https://api.osv.dev/v1/query")!)
        req.httpMethod = "POST"
        req.httpBody = JSONValue.object(["package": ["name": .string(name), "ecosystem": .string(ecosystem)], "version": .string(version)]).serialized().data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return (json["vulns"]?.array ?? []).compactMap { v in v["id"]?.string.map { Vuln(id: $0, summary: v["summary"]?.string) } }
    }
}
