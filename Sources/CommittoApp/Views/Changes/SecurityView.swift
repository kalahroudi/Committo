import SwiftUI
import CommittoCore

struct SecurityView: View {
    @Environment(AppModel.self) var model
    @State private var findings: [Finding] = []
    @State private var scanning = false
    @State private var scanned = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading) { Text("Security scan").font(.title2.bold()); Text("Secrets, risky patterns and CI red flags in your uncommitted changes. Runs fully offline.").foregroundStyle(.secondary) }
                    Spacer()
                    Button { Task { await scan() } } label: { Label(scanning ? "Scanning…" : "Scan now", systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(scanning)
                }
                if scanned && findings.isEmpty { Card { Label("No findings in your changes", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline) } }
                HStack { ForEach(Severity.allCases.reversed(), id: \.self) { s in Chip(text: "\(s.label) \(findings.filter { $0.severity == s }.count)", tint: Theme.color(s)) } }
                ForEach(findings) { f in Card { FindingRow(f: f) } }
            }.padding(18)
        }.task { await scan() }
    }
    func scan() async {
        guard let r = model.current else { return }
        scanning = true; defer { scanning = false; scanned = true }
        findings = (try? await SecurityScanner().scanWorkingTree(r)) ?? []
    }
}
