import SwiftUI
import Network
import CommittoCore

@MainActor @Observable
final class CIModel {
    var workflows: [Workflow] = []
    /// Last 5,000 lines of the run; older lines are dropped (a long `act` run can print millions).
    var log = RingBuffer<String>(capacity: 5_000)
    var running = false
    var lastResult: Bool?
    var servers: [CIServerConfig] = CIServerStore.load()
    var discovered: [CIDiscovery.Found] = []
    var selectedRunner = "local"          // "local" or server name
    private let discovery = CIDiscovery()
    private var task: Task<Void, Never>?

    func startDiscovery() { discovery.start { [weak self] f in Task { @MainActor in self?.discovered = f } } }
    var runner: CIRunner? { selectedRunner == "local" ? ActRunner() : servers.first { $0.name == selectedRunner }?.runner() }

    func load(_ repo: GitRepository) async {
        guard ActRunner.isInstalled || selectedRunner != "local" else { workflows = []; return }
        let r: CIRunner? = runner
        workflows = (try? await r?.workflows(in: repo.url)) ?? []
    }
    func run(_ w: Workflow?, repo: GitRepository, dry: Bool) {
        guard let runner else { return }
        log.removeAll(); running = true; lastResult = nil
        var req = CIRunRequest(repoPath: repo.url.path, workflowFile: w?.file, job: w?.job, dryRun: dry)
        req.event = w?.events.split(separator: ",").first.map(String.init) ?? "push"
        task = Task {
            do { for try await e in runner.run(req) { switch e { case .log(let l): log.append(String(l.prefix(4_000))); case .finished(let ok): lastResult = ok } } }
            catch { log.append("✗ \(error.localizedDescription)"); lastResult = false }
            running = false
        }
    }
    func stop() { task?.cancel(); running = false }
    func add(name: String, url: String, token: String) {
        let s = CIServerConfig(name: name, url: url); Keychain.set(token, for: s.keychainAccount)
        servers.removeAll { $0.name == name }; servers.append(s); CIServerStore.save(servers)
    }
}

struct CIView: View {
    @Environment(AppModel.self) var model
    @State private var ci = CIModel()

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("CI Runners").font(.title2.bold()); Spacer()
                        Picker("Runner", selection: $ci.selectedRunner) {
                            Text("This Mac (act)").tag("local")
                            ForEach(ci.servers) { Text($0.name).tag($0.name) }
                        }.frame(width: 220).onChange(of: ci.selectedRunner) { _, _ in Task { if let r = model.current { await ci.load(r) } } } }
                    if ci.selectedRunner == "local" { prerequisites }
                    ForEach(ci.workflows) { w in
                        Card {
                            HStack {
                                VStack(alignment: .leading) { Text(w.name.isEmpty ? w.job : w.name).fontWeight(.semibold); Text("\(w.file) · job \(w.job)").font(.caption).foregroundStyle(.secondary); Chip(text: w.events, tint: Theme.accent2) }
                                Spacer()
                                Button("Dry run") { if let r = model.current { ci.run(w, repo: r, dry: true) } }.disabled(ci.running)
                                Button { if let r = model.current { ci.run(w, repo: r, dry: false) } } label: { Label("Run", systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(ci.running)
                            }
                        }
                    }
                    if ci.workflows.isEmpty { EmptyState(symbol: "gearshape.2", title: "No workflows found", message: "Add .github/workflows/*.yml, or pick a different runner.") }
                    lanSection
                }.padding(18)
            }.frame(minWidth: 420)
            VStack(spacing: 0) {
                HStack { if ci.running { ProgressView().controlSize(.small) } else if let ok = ci.lastResult { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? .green : .red) }
                    Text(ci.running ? "Running…" : ci.lastResult == nil ? "Output" : ci.lastResult == true ? "Passed" : "Failed").font(.headline); Spacer()
                    if ci.running { Button("Stop") { ci.stop() } } }.padding(12)
                Divider()
                ScrollViewReader { p in
                    ScrollView { LazyVStack(alignment: .leading, spacing: 1) {
                        if ci.log.dropped > 0 { Text("… \(ci.log.dropped) earlier lines dropped").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                        ForEach(ci.log.indexed(), id: \.id) { i, l in
                            Text(l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i) } }.padding(10).frame(maxWidth: .infinity, alignment: .leading) }
                        .onChange(of: ci.log.totalAppended) { _, c in p.scrollTo(c - 1, anchor: .bottom) }
                }.background(Color.black.opacity(0.25))
            }.frame(minWidth: 320)
        }
        .task(id: model.current?.id) { ci.startDiscovery(); if let r = model.current { await ci.load(r) } }
    }

    var prerequisites: some View {
        Card { VStack(alignment: .leading, spacing: 6) {
            Label(ActRunner.isInstalled ? "act installed" : "act not found — brew install act", systemImage: ActRunner.isInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ActRunner.isInstalled ? .green : .orange)
            Label(Shell.which("docker") != nil ? "Docker CLI found" : "Docker-compatible runtime needed (Docker Desktop, OrbStack, Colima)", systemImage: Shell.which("docker") != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(Shell.which("docker") != nil ? .green : .orange)
        }.font(.callout) }
    }

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    var lanSection: some View {
        Card { VStack(alignment: .leading, spacing: 8) {
            Label("LAN runners", systemImage: "network").font(.headline)
            Text("Run `committo ci-serve` on any Mac/Linux box with act + Docker. It advertises over Bonjour.").font(.caption).foregroundStyle(.secondary)
            ForEach(ci.discovered) { f in HStack { Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green); Text(f.name); Spacer()
                Button("Use") { name = f.name; url = "http://\(f.name.replacingOccurrences(of: " ", with: "-")).local:7771" }.buttonStyle(.link) } }
            HStack { TextField("Name", text: $name); TextField("http://host.local:7771", text: $url) }.textFieldStyle(.roundedBorder)
            HStack { SecureField("Token", text: $token).textFieldStyle(.roundedBorder); Button("Add") { ci.add(name: name, url: url, token: token); token = "" }.disabled(name.isEmpty || url.isEmpty) }
            Text("Transport is plain HTTP on your LAN, protected by a bearer token. Put it behind a VPN or reverse proxy for anything beyond a trusted network.").font(.caption2).foregroundStyle(.tertiary)
        } }
    }
}
