import XCTest
@testable import CommittoCore

/// Runs against real ssh-keygen and git in a temp HOME with an isolated global config, never the user's own.
final class SigningTests: XCTestCase {
    var home: URL!
    var env: [String: String] { ["HOME": home.path, "GIT_CONFIG_GLOBAL": home.appendingPathComponent("gitconfig").path, "GIT_CONFIG_NOSYSTEM": "1"] }
    var repoDir: URL!
    var repo: GitRepository!

    override func setUp() async throws {
        try XCTSkipIf(Shell.which("ssh-keygen") == nil, "ssh-keygen not installed")
        home = FileManager.default.temporaryDirectory.appendingPathComponent("committo-sign-\(UUID().uuidString)")
        repoDir = home.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try await GitRepository.initialize(at: repoDir)
        repo = GitRepository(url: repoDir)
        for (k, v) in [("user.name", "T"), ("user.email", "t@example.com")] { _ = try await Shell.check("git", ["config", "--local", k, v], cwd: repoDir, env: env) }
    }
    override func tearDown() async throws { if let home { try? FileManager.default.removeItem(at: home) } }

    func key(_ name: String = "id_test") async throws -> SSHKey {
        try await Signing.generateKey(at: home.appendingPathComponent(".ssh/\(name)"), comment: "test key")
    }
    func commit(_ msg: String) async throws {
        try "x\(UUID().uuidString)".write(to: repoDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = try await Shell.check("git", ["add", "-A"], cwd: repoDir, env: env)
        _ = try await Shell.check("git", ["commit", "-q", "-m", msg], cwd: repoDir, env: env)
    }
    func head() async throws -> String { try await Shell.check("git", ["rev-parse", "HEAD"], cwd: repoDir).trimmingCharacters(in: .whitespacesAndNewlines) }
    func sig(_ hash: String) async throws -> SignatureInfo {
        // Verification must see the same isolated config, so read it through git with the env applied.
        let out = try await Shell.check("git", ["log", "--no-walk", "--format=%G?%x1f%GS%x1f%GK", hash], cwd: repoDir, env: env)
        let f = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
        return SignatureInfo(status: SignatureStatus(rawValue: f[0]) ?? .cannotCheck, signer: f.count > 1 && !f[1].isEmpty ? f[1] : nil, key: f.count > 2 && !f[2].isEmpty ? f[2] : nil)
    }

    func testGenerateKeyCreatesPairWithPrivatePermissionsAndRefusesOverwrite() async throws {
        let k = try await key()
        XCTAssertTrue(k.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertEqual(k.comment, "test key")
        let attrs = try FileManager.default.attributesOfItem(atPath: k.privateKeyPath.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int ?? 0) & 0o077, 0, "private key must not be group/world accessible")
        do { _ = try await key(); XCTFail("must not overwrite") } catch is SigningError {}
        XCTAssertEqual(Signing.sshKeys(in: home.appendingPathComponent(".ssh")).map(\.publicKeyPath), [k.publicKeyPath])
    }

    func testAllowedSignersIsIdempotentAndKeepsOtherEntries() throws {
        let f = home.appendingPathComponent("signers")
        XCTAssertTrue(try Signing.addAllowedSigner(file: f, principal: "a@x.com", publicKey: "ssh-ed25519 AAAA1 comment"))
        XCTAssertFalse(try Signing.addAllowedSigner(file: f, principal: "a@x.com", publicKey: "ssh-ed25519 AAAA1 other comment"))
        XCTAssertTrue(try Signing.addAllowedSigner(file: f, principal: "b@x.com", publicKey: "ssh-ed25519 AAAA2"))
        XCTAssertTrue(try Signing.addAllowedSigner(file: f, principal: "a@x.com", publicKey: "ssh-ed25519 AAAA3"))     // second key, same person
        let lines = try String(contentsOf: f, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("a@x.com namespaces=\"git\" ssh-ed25519 AAAA1"))
        XCTAssertThrowsError(try Signing.addAllowedSigner(file: f, principal: "bad principal", publicKey: "ssh-ed25519 AAAA"))
    }

    func testConfigureLocalThenSignedCommitVerifies() async throws {
        let k = try await key()
        try await Signing.configureSSH(key: k, email: "t@example.com", scope: .local(repo), env: env)
        let setup = await Signing.current(in: repo, env: env)
        XCTAssertEqual(setup.format, "ssh"); XCTAssertTrue(setup.signCommits); XCTAssertEqual(setup.key, k.publicKeyPath.path)
        XCTAssertTrue(setup.isConfigured)
        XCTAssertEqual(Signing.diagnose(setup, email: "t@example.com"), [])

        try await commit("signed")
        let info = try await sig(try await head())
        XCTAssertEqual(info.status, .valid)
        XCTAssertEqual(info.signer, "t@example.com")
        XCTAssertTrue(info.status.isVerified)
    }

    func testUnsignedAndUnknownKeyAreDistinguished() async throws {
        try await commit("plain")                                       // no signing configured at all
        let plain = try await head()
        let k = try await key()
        try await Signing.configureSSH(key: k, email: "t@example.com", scope: .local(repo), env: env)
        try await commit("signed")
        let signed = try await head()
        // Forget the signer: the signature is still cryptographically fine but not trusted.
        try "".write(to: repoDir.appendingPathComponent(".git/allowed_signers"), atomically: true, encoding: .utf8)
        let a = try await sig(plain), b = try await sig(signed)
        XCTAssertEqual(a.status, .unsigned)
        XCTAssertTrue(b.status.isSigned, "got \(b.status)")
        XCTAssertFalse(b.status.isVerified, "key removed from allowed signers must not verify, got \(b.status)")
    }

    func testRepoAPIReturnsStatusesForRequestedCommits() async throws {
        let k = try await key()
        try await commit("plain"); let plain = try await head()
        // GitRepository.signatures uses the process environment; point it at the repo-local config only.
        try await Signing.configureSSH(key: k, email: "t@example.com", scope: .local(repo), env: env)
        try await commit("signed"); let signed = try await head()
        let got = try await repo.signatures(for: [plain, signed])
        XCTAssertEqual(got[plain]?.status, .unsigned)
        XCTAssertEqual(got[signed]?.status, .valid)
        XCTAssertEqual(got[signed]?.signer, "t@example.com")
    }

    func testGlobalScopeWritesOnlyTheIsolatedGlobalConfig() async throws {
        let k = try await key()
        let signers = home.appendingPathComponent("allowed")
        try await Signing.configureSSH(key: k, email: "t@example.com", scope: .global, allowedSigners: signers, env: env)
        let g = await Signing.current(in: nil, env: env)
        XCTAssertEqual(g.format, "ssh"); XCTAssertEqual(g.allowedSignersFile, signers.path)
        try await Signing.disable(scope: .global, env: env)
        let off = await Signing.current(in: nil, env: env)
        XCTAssertFalse(off.signCommits)
        XCTAssertEqual(off.key, k.publicKeyPath.path, "disable keeps the key configured")
        XCTAssertTrue(Signing.diagnose(off, email: "t@example.com").contains { $0.contains("signing is off") })
    }

    func testDiagnoseExplainsEachProblem() {
        var s = SigningSetup()
        XCTAssertEqual(Signing.diagnose(s, email: nil).count, 2)                      // off + no key
        s.format = "ssh"; s.signCommits = true; s.key = "/nonexistent/key.pub"
        let p = Signing.diagnose(s, email: "me@x.com")
        XCTAssertTrue(p.contains { $0.contains("does not exist") })
        XCTAssertTrue(p.contains { $0.contains("allowedSignersFile is not set") })
        s.allowedSignersFile = "/nonexistent/allowed"
        XCTAssertTrue(Signing.diagnose(s, email: "me@x.com").contains { $0.contains("allowed-signers file") })
    }

    func testProviderSigningKeyRequests() throws {
        let gh = GitHubProvider(token: "tok").signingKeyRequest(title: "Mac", publicKey: "ssh-ed25519 AAAA c")
        XCTAssertEqual(gh.url?.absoluteString, "https://api.github.com/user/ssh_signing_keys")
        XCTAssertEqual(gh.httpMethod, "POST")
        XCTAssertEqual(gh.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let ghBody = JSONValue.parse(String(decoding: gh.httpBody ?? Data(), as: UTF8.self))
        XCTAssertEqual(ghBody?["key"]?.string, "ssh-ed25519 AAAA c"); XCTAssertEqual(ghBody?["title"]?.string, "Mac")

        let gl = GitLabProvider(token: "tok").signingKeyRequest(title: "Mac", publicKey: "ssh-ed25519 AAAA c")
        XCTAssertEqual(gl.url?.absoluteString, "https://gitlab.com/api/v4/user/keys")
        let glBody = JSONValue.parse(String(decoding: gl.httpBody ?? Data(), as: UTF8.self))
        XCTAssertEqual(glBody?["usage_type"]?.string, "signing", "must be a signing key, not an authentication key")
    }
}
