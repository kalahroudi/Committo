import SwiftUI
import CommittoCore

struct BranchesView: View {
    @Environment(AppModel.self) var model
    @State private var newName = ""
    @State private var compare: Branch?

    var body: some View {
        List {
            SwiftUI.Section("New branch") {
                HStack { TextField("feature/awesome", text: $newName).textFieldStyle(.roundedBorder)
                    Button("Create & switch") { let n = newName; model.perform("Creating") { try await $0.createBranch(n) }; newName = "" }.disabled(newName.isEmpty) }
            }
            SwiftUI.Section("Local") { ForEach(model.branches.filter { !$0.isRemote }) { branchRow($0) } }
            SwiftUI.Section("Remote") { ForEach(model.branches.filter(\.isRemote)) { branchRow($0) } }
            if !model.stashes.isEmpty {
                SwiftUI.Section("Stashes") {
                    ForEach(model.stashes) { s in
                        HStack { Image(systemName: "tray.full"); Text(s.message).lineLimit(1); Spacer()
                            Button("Apply") { model.perform("Applying") { try await $0.stashApply(s.ref) } }
                            Button("Pop") { model.perform("Popping") { try await $0.stashPop(s.ref) } }
                            Button("Drop", role: .destructive) { model.perform("Dropping") { try await $0.stashDrop(s.ref) } } }.buttonStyle(.link)
                    }
                }
            }
            if model.worktrees.count > 1 {
                SwiftUI.Section("Worktrees") {
                    ForEach(model.worktrees) { w in
                        HStack { Image(systemName: "square.on.square"); VStack(alignment: .leading) { Text(w.branch ?? "detached").fontWeight(.medium); Text(w.path).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Button("Open") { Task { await model.open(URL(fileURLWithPath: w.path)) } }.buttonStyle(.link) }
                    }
                }
            }
            if !model.tags.isEmpty { SwiftUI.Section("Tags") { ForEach(model.tags.prefix(30)) { t in HStack { Image(systemName: "tag"); Text(t.name); Spacer(); Text(t.date.relative).font(.caption).foregroundStyle(.secondary) } } } }
        }
    }

    func branchRow(_ b: Branch) -> some View {
        HStack(spacing: 8) {
            Image(systemName: b.isCurrent ? "location.fill" : "arrow.triangle.branch").foregroundStyle(b.isCurrent ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) { Text(b.name).fontWeight(b.isCurrent ? .semibold : .regular)
                Text("\(b.subject) · \(b.lastCommit.relative)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            SyncBadge(ahead: b.ahead, behind: b.behind)
            if !b.isCurrent && !b.isRemote {
                Menu {
                    Button("Switch to") { model.perform("Switching") { try await $0.checkout(b.name) } }
                    Button("Merge into current") { model.perform("Merging") { try await $0.merge(b.name) } }
                    Button("Rebase current onto") { model.perform("Rebasing") { try await $0.rebase(onto: b.name) } }
                    Divider(); Button("Delete", role: .destructive) { model.perform("Deleting") { try await $0.deleteBranch(b.name, force: true) } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
            }
        }
    }
}

struct ReflogView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        List(model.reflog) { e in
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.gradient)
                VStack(alignment: .leading) { Text(e.message).lineLimit(1); Text("\(e.selector) · \(e.date.relative)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Chip(text: String(e.hash.prefix(7)), tint: Theme.accent)
                Button("Restore to new branch") { model.perform("Restoring") { try await $0.createBranch("restore-\(e.hash.prefix(7))", from: e.hash) } }.buttonStyle(.link)
            }
        }.overlay { if model.reflog.isEmpty { EmptyState(symbol: "clock.arrow.circlepath", title: "Nothing to recover", message: "The reflog shows every place HEAD has been — lost commits show up here.") } }
    }
}
