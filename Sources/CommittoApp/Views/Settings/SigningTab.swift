import SwiftUI
import CommittoCore

/// Commit signing wizard (SPEC §9): pick or generate an SSH key, write git's config, register the key with connected hosts.
struct SigningTab: View {
    @Environment(AppModel.self) var model
    @State private var setup = SigningSetup()
    @State private var keys: [SSHKey] = []
    @State private var selectedKey = ""
    @State private var email = ""
    @State private var status = ""
    @State private var busy = false
    @State private var uploadTarget: Account?

    var problems: [String] { Signing.diagnose(setup, email: email.isEmpty ? nil : email) }
    var chosen: SSHKey? { keys.first { $0.publicKeyPath.path == selectedKey } }

    var body: some View {
        Form {
            SwiftUI.Section("Status") {
                if problems.isEmpty {
                    Label("Commits are signed and can be verified", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                }
            }
            SwiftUI.Section("Key") {
                Picker("SSH key", selection: $selectedKey) {
                    Text("Choose…").tag("")
                    ForEach(keys) { k in Text("\(k.privateKeyPath.lastPathComponent) · \(k.type) \(k.comment)").tag(k.publicKeyPath.path) }
                }
                TextField("Your commit email", text: $email, prompt: Text("you@example.com"))
                HStack {
                    Button("Generate new key") { Task { await generate() } }.disabled(busy || email.isEmpty)
                    Spacer()
                    Button("Turn off signing", role: .destructive) { Task { await turnOff() } }.disabled(!setup.signCommits)
                    Button("Turn on signing") { Task { await turnOn() } }.buttonStyle(.borderedProminent).disabled(busy || chosen == nil || email.isEmpty)
                }
                Text("New keys are ed25519 files in ~/.ssh with no passphrase. Add a passphrase with ssh-keygen -p and store it in the Keychain if you want one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Verified badge on your hosts") {
                if model.accounts.isEmpty { Text("Connect an account first (Accounts tab).").foregroundStyle(.secondary) }
                ForEach(model.accounts) { a in
                    HStack {
                        Label("\(a.username) · \(a.host)", systemImage: a.provider.symbol)
                        Spacer()
                        Button("Add public key as signing key") { uploadTarget = a }.disabled(chosen == nil)
                    }
                }
                Text("This uploads only the public key. Hosts show a Verified badge once the key is registered as a signing key.").font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .confirmationDialog("Upload your public key to \(uploadTarget?.host ?? "")?", isPresented: Binding(get: { uploadTarget != nil }, set: { if !$0 { uploadTarget = nil } }), titleVisibility: .visible) {
            Button("Upload public key") { if let a = uploadTarget { Task { await upload(a) } } }
        } message: { Text("\(chosen?.privateKeyPath.lastPathComponent ?? "") (public half only) will be added to your account as a signing key.") }
    }

    func reload() async {
        setup = await Signing.current()
        keys = Signing.sshKeys()
        if selectedKey.isEmpty { selectedKey = keys.first { $0.publicKeyPath.path == setup.key }?.publicKeyPath.path ?? "" }
        if email.isEmpty, let r = try? await Shell.run("git", ["config", "--global", "--get", "user.email"]), r.ok {
            email = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func generate() async {
        busy = true; defer { busy = false }
        var name = "committo_signing", n = 1
        while FileManager.default.fileExists(atPath: Signing.defaultSSHDirectory.appendingPathComponent(name).path) { n += 1; name = "committo_signing_\(n)" }
        do {
            let k = try await Signing.generateKey(at: Signing.defaultSSHDirectory.appendingPathComponent(name), comment: "Committo signing \(email)")
            await reload(); selectedKey = k.publicKeyPath.path; status = "Created \(k.privateKeyPath.path)"
        } catch { status = error.localizedDescription }
    }
    func turnOn() async {
        guard let k = chosen else { return }
        busy = true; defer { busy = false }
        do { try await Signing.configureSSH(key: k, email: email, scope: .global); status = "Signing is on for all repos (git config --global)."; await reload() }
        catch { status = error.localizedDescription }
    }
    func turnOff() async {
        do { try await Signing.disable(scope: .global); status = "Signing is off. Your key and allowed-signers file were kept."; await reload() }
        catch { status = error.localizedDescription }
    }
    func upload(_ a: Account) async {
        guard let k = chosen, let token = AccountStore.shared.token(for: a), let provider = Providers.make(for: a, token: token) else { status = "No token for \(a.host)"; return }
        do { try await provider.uploadSigningKey(title: "Committo – \(Host.current().localizedName ?? "Mac")", publicKey: k.publicKey); status = "Added to \(a.host)." }
        catch { status = "\(a.host): \(error.localizedDescription)" }
    }
}
