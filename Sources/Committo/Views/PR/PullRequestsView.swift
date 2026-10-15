import SwiftUI
import CommittoCore

struct PullRequestsView: View {
    @Environment(AppModel.self) var model
    @State private var prs: [PullRequest] = []
    @State private var selected: PullRequest?
    @State private var loading = false
    @State private var message: String?
    @State private var slug: String?
    @State private var provider: HostingProvider?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack { Text(slug ?? "Pull requests").font(.headline); Spacer(); if loading { ProgressView().controlSize(.small) }
                    IconButton(symbol: "arrow.clockwise", help: "Reload") { Task { await load() } } }.padding(10).background(.bar)
                if let message { EmptyState(symbol: "person.badge.key", title: "Connect an account", message: message) }
                else { List(prs, selection: Binding(get: { selected?.id }, set: { id in selected = prs.first { $0.id == id } })) { pr in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text("#\(pr.number)").foregroundStyle(.secondary); Text(pr.title).fontWeight(.medium).lineLimit(1); if pr.isDraft { Chip(text: "Draft") } }
                        HStack { Text("@\(pr.author)"); Text("· \(pr.updatedAt.relative)"); Spacer()
                            let k = AgentKind.detect(branch: pr.headRef, author: pr.author); if k != .human { Chip(text: k.displayName, symbol: k.symbol, tint: Theme.accent2) } }
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(pr.id).padding(.vertical, 2)
                } }
            }.frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
            Group {
                if let pr = selected, let provider { PRDeepDiveView(pr: pr, provider: provider).id(pr.id) }
                else { EmptyState(symbol: "arrow.triangle.pull", title: "Deep dive", message: "Select a PR for risk scoring, a security scan and an agent review.") }
            }.frame(minWidth: 460)
        }
        .task(id: model.current?.id) { await load() }
    }

    func load() async {
        guard let repo = model.current, let remote = await repo.remoteURL() else { message = "This repo has no remote."; return }
        guard let (kind, host, path) = Self.parse(remote) else { message = "Unrecognised remote: \(remote)"; return }
        guard let acct = model.accounts.first(where: { $0.provider == kind && $0.host == host }) else { message = "Add a \(kind.displayName) account in Settings → Accounts (OAuth, token, or gh CLI)."; return }
        guard let token = await AccountStore.shared.resolveToken(for: acct), let p = Providers.make(for: acct, token: token) else { message = "\(kind.displayName) pull requests aren't supported yet; auth and clone still work."; return }
        message = nil; slug = path; provider = p; loading = true
        defer { loading = false }
        do { prs = try await p.pullRequests(repo: path, state: "open") } catch { model.error = error.localizedDescription }
    }

    static func parse(_ remote: String) -> (ProviderKind, String, String)? {
        var host = "", path = ""
        if remote.hasPrefix("git@") { let r = remote.dropFirst(4).split(separator: ":", maxSplits: 1); guard r.count == 2 else { return nil }; host = String(r[0]); path = String(r[1]) }
        else if let u = URL(string: remote), let h = u.host { host = h; path = String(u.path.dropFirst()) } else { return nil }
        path = path.replacingOccurrences(of: ".git", with: "")
        let kind: ProviderKind = host.contains("github") ? .github : host.contains("gitlab") ? .gitlab : host.contains("bitbucket") ? .bitbucket : host.contains("azure") || host.contains("visualstudio") ? .azureDevOps : .gitea
        return (kind, host, path)
    }
}

struct PRDeepDiveView: View {
    @Environment(AppModel.self) var model
    let pr: PullRequest, provider: HostingProvider
    @State private var dive: PRDeepDive?
    @State private var review = ""
    @State private var reviewing = false
    @State private var posted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pr.title).font(.title2.bold())
                    Text("#\(pr.number) · \(pr.headRef) → \(pr.baseRef) · @\(pr.author)").foregroundStyle(.secondary)
                }
                if let d = dive {
                    HStack(alignment: .top, spacing: 12) {
                        RiskGauge(risk: d.risk).frame(width: 150)
                        Card { VStack(alignment: .leading, spacing: 6) { Text("Why").font(.subheadline.weight(.semibold))
                            ForEach(d.risk.reasons.isEmpty ? ["Nothing notable"] : d.risk.reasons, id: \.self) { Label($0, systemImage: "circle.fill").font(.caption).labelStyle(BulletStyle()) } } }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Security scan", systemImage: "lock.shield").font(.headline)
                            if d.findings.isEmpty { Label("No findings in added lines", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                            ForEach(d.findings.prefix(40)) { FindingRow(f: $0) }
                        }
                    }
                    if !d.checks.isEmpty {
                        Card { VStack(alignment: .leading, spacing: 6) { Label("Checks", systemImage: "checklist").font(.headline)
                            ForEach(d.checks, id: \.name) { c in HStack { Image(systemName: icon(c)).foregroundStyle(tint(c)); Text(c.name); Spacer(); Text(c.conclusion ?? c.status).font(.caption).foregroundStyle(.secondary) } } } }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Label("Agent review", systemImage: "sparkles").font(.headline); Spacer()
                                if !review.isEmpty && !reviewing { Button(posted ? "Posted ✓" : "Post as comment") { post() }.disabled(posted) }
                                Button { run(d) } label: { Text(reviewing ? "Reviewing…" : review.isEmpty ? "Run review" : "Re-run") }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(reviewing || model.agent == nil) }
                            if model.agent == nil { Text("Install Claude Code or add an API key in Settings → Agents.").font(.caption).foregroundStyle(.secondary) }
                            if reviewing { ProgressView().controlSize(.small) }
                            if !review.isEmpty { Text(LocalizedStringKey(review)).textSelection(.enabled) }
                        }
                    }
                    Text("Files · \(d.files.count)").font(.headline)
                    ForEach(d.files) { f in HStack { Text(f.filename).font(.system(size: 12, design: .monospaced)).lineLimit(1); Spacer(); ChurnBar(adds: f.additions, dels: f.deletions) } }
                } else { ProgressView("Analysing…") }
            }.padding(18)
        }
        .task {
            async let files = try? provider.files(repo: pr.repo, number: pr.number)
            async let checks = try? provider.checks(repo: pr.repo, sha: pr.headSHA)
            dive = PRAnalyzer.analyze(pr: pr, files: await files ?? [], checks: await checks ?? [])
        }
    }
    func icon(_ c: CheckRun) -> String { c.conclusion == "success" ? "checkmark.circle.fill" : c.conclusion == nil ? "clock" : "xmark.circle.fill" }
    func tint(_ c: CheckRun) -> Color { c.conclusion == "success" ? .green : c.conclusion == nil ? .yellow : .red }
    func run(_ d: PRDeepDive) {
        guard let agent = model.agent, let repo = model.current else { return }
        reviewing = true; review = ""; posted = false
        Task { defer { reviewing = false }
            do { review = try await agent.complete(AgentTask(prompt: PRAnalyzer.reviewPrompt(d), workingDirectory: repo.url, maxTurns: 8)).text } catch { review = "Review failed: \(error.localizedDescription)" } }
    }
    func post() { Task { do { try await provider.comment(repo: pr.repo, number: pr.number, body: review + "\n\n---\n_Reviewed with Committo_"); posted = true } catch { model.error = error.localizedDescription } } }
}

struct BulletStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(alignment: .top, spacing: 6) { configuration.icon.font(.system(size: 4)).padding(.top, 5); configuration.title } }
}

struct RiskGauge: View {
    let risk: PRRisk
    var color: Color { risk.score >= 60 ? .red : risk.score >= 30 ? .orange : .green }
    var body: some View {
        Card { VStack {
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(.quaternary, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * CGFloat(risk.score) / 100).stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(135))
                VStack(spacing: 0) { Text("\(risk.score)").font(.system(size: 28, weight: .bold, design: .rounded)); Text(risk.level + " risk").font(.caption).foregroundStyle(.secondary) }
            }.frame(width: 110, height: 110)
        }.frame(maxWidth: .infinity) }
    }
}

struct FindingRow: View {
    let f: Finding
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Chip(text: f.severity.label, tint: Theme.color(f.severity)).frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.system(size: 13, weight: .medium))
                Text("\(f.file):\(f.line)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                if !f.snippet.isEmpty { Text(f.snippet).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1) }
                Text(f.advice).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
