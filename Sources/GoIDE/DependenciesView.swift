import AppKit
import GoIDECore
import SwiftUI

/// Sidebar: the project's Go modules (go.work members), their requirements and available updates.
struct DependenciesView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if workspace.modules.isEmpty {
                VStack(spacing: 8) {
                    Text("No go.mod in this folder").foregroundStyle(.secondary)
                    if workspace.rootURL != nil {
                        Button("Initialize Module…") { initModule() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    workspaceSection
                    ForEach(workspace.modules) { group in
                        ModuleSection(group: group, showsHeader: workspace.modules.count > 1 || workspace.goWork != nil)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onAppear { workspace.checkModuleUpdatesIfNeeded() }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            if workspace.isCheckingModuleUpdates {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").font(.caption).foregroundStyle(.secondary)
            } else if let error = workspace.moduleUpdatesError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(error)
            } else {
                let count = workspace.modules.reduce(0) { $0 + workspace.upgradableDirect(in: $1).count }
                Text(count == 0 ? "Up to date" : "\(count) update\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { workspace.checkModuleUpdates() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Check for Updates (go list -m -u)")
                .disabled(workspace.isCheckingModuleUpdates || workspace.modules.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder private var workspaceSection: some View {
        if let goWork = workspace.goWork {
            Section {
                ForEach(goWork.uses, id: \.line) { use in
                    Label(use.path, systemImage: "shippingbox")
                        .font(.system(size: 12, design: .monospaced))
                        .onTapGesture(count: 2) {
                            if let url = workspace.goWorkURL {
                                workspace.navigate(to: url, position: TextPosition(line: use.line, character: 0))
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Workspace (go.work\(goWork.goVersion.map { ", go \($0)" } ?? ""))")
                    Spacer()
                    Menu {
                        Button("Open go.work") { if let url = workspace.goWorkURL { workspace.openFile(url) } }
                        Button("Sync (go work sync)") { workspace.syncGoWork() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        } else if workspace.modules.count > 1 {
            Section {
                HStack {
                    Text("\(workspace.modules.count) modules").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Create go.work") { workspace.createGoWork() }
                        .controlSize(.small)
                        .fixedSize()
                        .help("go work init with every module, so gopls and go build see them together")
                }
            }
        }
    }

    private func initModule() {
        guard let root = workspace.rootURL,
              let path = Prompt.text(title: "Initialize Module", message: "go mod init <module path>",
                                     initial: "example.com/\(root.lastPathComponent)", confirm: "Initialize")
        else { return }
        workspace.runGo(["mod", "init", path]) { _ in workspace.reloadModules() }
    }
}

private struct ModuleSection: View {
    @Environment(Workspace.self) private var workspace
    let group: ModuleGroup
    let showsHeader: Bool
    @State private var showsIndirect = false

    var body: some View {
        Section {
            if !showsHeader { moduleSummary }
            ForEach(group.file.direct) { DependencyRow(group: group, requirement: $0) }
            if group.file.requires.isEmpty {
                Text("No dependencies").font(.caption).foregroundStyle(.secondary)
            }
            if !group.file.indirect.isEmpty {
                DisclosureGroup(isExpanded: $showsIndirect) {
                    ForEach(group.file.indirect) { DependencyRow(group: group, requirement: $0) }
                } label: {
                    Text("Indirect (\(group.file.indirect.count))").foregroundStyle(.secondary)
                }
            }
        } header: {
            if showsHeader {
                header
            }
        }
    }

    private var moduleSummary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                if let go = group.file.goVersion {
                    Text("go \(go)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            if workspace.goWork != nil {
                Image(systemName: group.inWorkspace ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(group.inWorkspace ? Color.green : Color.secondary)
                    .help(group.inWorkspace ? "In go.work" : "Not in go.work")
            }
            Text(group.name).lineLimit(1).truncationMode(.middle)
            if let go = group.file.goVersion { Text("go \(go)").foregroundStyle(.tertiary) }
            Spacer()
            actions
        }
        .textCase(nil)
    }

    private var actions: some View {
        let upgradable = workspace.upgradableDirect(in: group)
        return Menu {
            Button("Upgrade All Direct (\(upgradable.count))") {
                workspace.upgrade(upgradable.map(\.path), in: group)
            }
            .disabled(upgradable.isEmpty)
            Button("Tidy (go mod tidy)") { workspace.tidy(group) }
            Button("Open go.mod") { workspace.openRequirement(line: group.file.moduleLine, in: group) }
            if workspace.goWork != nil {
                Divider()
                if group.inWorkspace {
                    Button("Remove from go.work") { workspace.setInWorkspace(group, false) }
                } else {
                    Button("Add to go.work") { workspace.setInWorkspace(group, true) }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Module actions")
    }
}

private struct DependencyRow: View {
    @Environment(Workspace.self) private var workspace
    let group: ModuleGroup
    let requirement: GoModFile.Requirement

    var body: some View {
        let update = workspace.availableUpdate(for: requirement.path, in: group)
        let replacement = group.file.replacement(for: requirement.path)
        VStack(alignment: .leading, spacing: 2) {
            Text(requirement.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.head)
                .help(requirement.path)
            HStack(spacing: 4) {
                Text(requirement.version)
                if let replacement {
                    Image(systemName: "arrow.turn.down.right")
                    Text(replacement.newPath + (replacement.newVersion.map { " \($0)" } ?? ""))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let update {
                    Button { workspace.upgrade([requirement.path], in: group) } label: {
                        Text("↑ \(update)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(Color.green)
                    }
                    .buttonStyle(.plain)
                    .help("Upgrade to \(update) (go get \(requirement.path)@latest)")
                    .disabled(workspace.isRunning)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.openRequirement(line: requirement.line, in: group) }
        .contextMenu {
            if let update {
                Button("Upgrade to \(update)") { workspace.upgrade([requirement.path], in: group) }
            }
            Button("Show in go.mod") { workspace.openRequirement(line: requirement.line, in: group) }
            Button("Why Is This Needed? (go mod why)") { workspace.explainDependency(requirement.path, in: group) }
            Divider()
            Button("Open on pkg.go.dev") {
                if let url = URL(string: "https://pkg.go.dev/\(requirement.path)") { NSWorkspace.shared.open(url) }
            }
            Button("Copy Module Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(requirement.path, forType: .string)
            }
        }
    }
}
