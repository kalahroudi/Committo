import SwiftUI
import AppKit
import CommittoCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            AgentsTab().tabItem { Label("Agents", systemImage: "sparkles") }
            MCPTab().tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }.padding(20)
    }
}

struct AccountsTab: View {
    @Environment(AppModel.self) var model
    @State private var provider: ProviderKind = .github
    @State private var host = ""
    @State private var token = ""
    @State private var clientID = UserDefaults.standard.string(forKey: "oauthClientID") ?? ""
    @State private var status = ""
    @State private var deviceCode: DeviceCode?

    var body: some View {
        Form {
            SwiftUI.Section("Connected") {
                if model.accounts.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(model.accounts) { a in
                    HStack { Image(systemName: a.provider.symbol); VStack(alignment: .leading) { Text("\(a.username) · \(a.provider.displayName)"); Text("\(a.host) · \(a.method.rawValue)").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Button("Remove", role: .destructive) { AccountStore.shared.remove(a); model.accounts = AccountStore.shared.all() } }
                }
            }
            SwiftUI.Section("Add account") {
                Picker("Provider", selection: $provider) { ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) } }.onChange(of: provider) { _, p in host = p.defaultHost }
                TextField("Host", text: $host, prompt: Text(provider.defaultHost))
                if provider == .github && GitHubCLI.isInstalled {
                    Button("Sign in with GitHub CLI (gh)") { Task { await ghLogin() } }
                }
                if provider.supportsDeviceFlow {
                    TextField("OAuth app client ID", text: $clientID).onSubmit { UserDefaults.standard.set(clientID, forKey: "oauthClientID") }
                    Button("Sign in with browser (OAuth device flow)") { Task { await device() } }.disabled(clientID.isEmpty)
                    if let c = deviceCode { HStack { Text("Code:"); Text(c.userCode).font(.system(.title3, design: .monospaced).bold()).textSelection(.enabled)
                        Button("Copy & open") { model.copyToPasteboard(c.userCode); NSWorkspace.shared.open(c.verificationURL) } } }
                }
                SecureField("Personal access token", text: $token)
                HStack { Button("Add token") { Task { await addToken() } }.disabled(token.isEmpty)
                    Link("Create a token…", destination: URL(string: provider.tokenHelpURL)!) }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped).onAppear { host = provider.defaultHost }
    }

    func finish(_ method: AuthMethod, _ token: String, user: String) {
        let a = Account(provider: provider, host: host.isEmpty ? provider.defaultHost : host, username: user, method: method)
        AccountStore.shared.add(a, token: token); model.accounts = AccountStore.shared.all(); status = "Signed in as \(user)"; deviceCode = nil
    }
    func ghLogin() async {
        let h = host.isEmpty ? "github.com" : host
        if let t = await GitHubCLI.token(host: h), let u = await GitHubCLI.username(host: h) { finish(.ghCLI, t, user: u); await GitHubCLI.setupGit(); return }
        status = "Starting gh auth…"
        do { for try await line in GitHubCLI.loginWeb(host: h) {
            status = line
            if let r = line.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression) { let code = String(line[r]); model.copyToPasteboard(code); status = "Code \(code) copied — finish in your browser" }
        } } catch { status = error.localizedDescription }
        if let t = await GitHubCLI.token(host: h), let u = await GitHubCLI.username(host: h) { finish(.ghCLI, t, user: u); await GitHubCLI.setupGit() }
    }
    func device() async {
        UserDefaults.standard.set(clientID, forKey: "oauthClientID")
        let flow = DeviceFlow(provider: provider, host: host.isEmpty ? nil : host, clientID: clientID)
        do { let code = try await flow.start(); deviceCode = code; NSWorkspace.shared.open(code.verificationURL)
            let t = try await flow.poll(code); await save(t, method: .oauth) } catch { status = error.localizedDescription }
    }
    func addToken() async { await save(token, method: .token); token = "" }
    func save(_ t: String, method: AuthMethod) async {
        let h = host.isEmpty ? provider.defaultHost : host
        let probe = Account(provider: provider, host: h, username: "?", method: method)
        var user = "user"
        if let p = Providers.make(for: probe, token: t) { do { user = try await p.currentUser() } catch { status = "Token rejected: \(error.localizedDescription)"; return } }
        finish(method, t, user: user)
    }
}

struct AgentsTab: View {
    @Environment(AppModel.self) var model
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    var body: some View {
        @Bindable var model = model
        Form {
            SwiftUI.Section("Default agent") {
                Picker("Use", selection: $model.selectedAgentID) { ForEach(model.registry.backends, id: \.id) { Text($0.displayName).tag($0.id) } }
            }
            SwiftUI.Section("Detected") {
                ForEach(model.registry.backends, id: \.id) { b in
                    HStack { Image(systemName: b.kind.symbol).frame(width: 20); Text(b.displayName); Spacer()
                        Text(b.isAvailable ? "ready" : "not found").font(.caption).foregroundStyle(b.isAvailable ? .green : .secondary) }
                }
            }
            SwiftUI.Section("API keys (stored in Keychain)") {
                SecureField("Anthropic API key", text: $anthropicKey).onSubmit { Keychain.set(anthropicKey, for: "agent.anthropic"); anthropicKey = ""; model.registry = AgentRegistry() }
                SecureField("OpenAI-compatible API key", text: $openAIKey).onSubmit { Keychain.set(openAIKey, for: "agent.openai"); openAIKey = ""; model.registry = AgentRegistry() }
                Text("Claude Code runs headless via `claude -p` and uses your existing Claude login. Codex, Gemini, Aider, Command Code and dsh are invoked as CLIs; edit their argument templates in AgentBackend.swift presets or bridge any agent through MCP.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct MCPTab: View {
    @Environment(AppModel.self) var model
    var binary: String { Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath + "/Contents/MacOS/committo" : "committo" }
    var json: String {
        """
        { "mcpServers": { "committo": { "command": "\(binary)", "args": ["mcp"] } } }
        """
    }
    var body: some View {
        Form {
            SwiftUI.Section("Expose Committo to your agents") {
                Text("Agents can list repos, read status/diffs/log, run the security scan, see the Agent Lens, create branches, commit (blocked on high-severity findings) and run CI.").font(.callout).foregroundStyle(.secondary)
                LabeledContent("Claude Code") { Button("Install") { Task { _ = try? await Shell.run("claude", ["mcp", "add", "committo", "--", binary, "mcp"]) } }.disabled(Shell.which("claude") == nil) }
                LabeledContent("Cursor / Codex / others") { Button("Copy JSON config") { model.copyToPasteboard(json) } }
                Text(json).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }.formStyle(.grouped)
    }
}

struct GeneralTab: View {
    @AppStorage("menuBarOnly") var menuBarOnly = false
    var body: some View {
        Form {
            Toggle("Launch to menu bar only (no window)", isOn: $menuBarOnly)
            Text("Committo discovers repos under ~/Developer, ~/Code, ~/Projects, ~/src and ~/Documents/GitHub.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
