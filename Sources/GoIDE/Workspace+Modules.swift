import AppKit
import GoIDECore

/// One Go module in the project (a `go.mod`), for the Dependencies sidebar.
struct ModuleGroup: Identifiable, Equatable {
    let directory: URL
    let goModURL: URL
    var file: GoModFile
    /// Listed in the project's `go.work`.
    var inWorkspace: Bool

    var id: URL { directory }
    var name: String { file.module ?? directory.lastPathComponent }
}

extension Workspace {
    var goWorkURL: URL? { rootURL?.appendingPathComponent("go.work") }

    /// Re-reads go.work and every go.mod in the project (cheap; no `go` invocation).
    func reloadModules() {
        guard let rootURL else {
            modules = []
            goWork = nil
            return
        }
        goWork = goWorkURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(GoWorkFile.parse)
        let used = Set((goWork?.moduleDirectories(relativeTo: rootURL) ?? []).map { Self.key(for: $0) })
        modules = GoModuleFinder.goModFiles(under: rootURL).compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let directory = url.deletingLastPathComponent()
            return ModuleGroup(directory: directory, goModURL: url, file: GoModFile.parse(text),
                               inWorkspace: used.contains(Self.key(for: directory)))
        }
    }

    /// Newest version of `path` for `group`, if an upgrade is available.
    func availableUpdate(for path: String, in group: ModuleGroup) -> String? {
        moduleUpdates[group.directory]?[path]
    }

    func upgradableDirect(in group: ModuleGroup) -> [GoModFile.Requirement] {
        group.file.direct.filter { availableUpdate(for: $0.path, in: group) != nil }
    }

    /// `go list -m -u -json all` per module (once at the root for a go.work workspace). Hits the network.
    func checkModuleUpdates() {
        guard let rootURL, !isCheckingModuleUpdates, !modules.isEmpty else { return }
        isCheckingModuleUpdates = true
        moduleUpdatesError = nil
        checkedModuleUpdatesRoot = rootURL
        let groups = modules
        let workspaceMode = goWork != nil
        Task {
            var updates: [URL: [String: String]] = [:]
            var failure: String?
            // In a go.work workspace one listing covers every member module.
            let runs: [(URL, [ModuleGroup])] = workspaceMode
                ? [(rootURL, groups.filter(\.inWorkspace))] + groups.filter { !$0.inWorkspace }.map { ($0.directory, [$0]) }
                : groups.map { ($0.directory, [$0]) }
            for (directory, members) in runs where !members.isEmpty {
                let result = await Task.detached {
                    GoCommand.run(["list", "-m", "-u", "-json", "-e", "all"], in: directory)
                }.value
                let listed = GoModuleList.parse(result.output)
                if listed.isEmpty, result.status != 0 {
                    failure = result.errorOutput.split(separator: "\n").first.map(String.init) ?? "go list failed"
                    continue
                }
                var latest: [String: String] = [:]
                for module in listed where !module.isMain {
                    if let version = module.latestVersion { latest[module.path] = version }
                }
                for member in members { updates[member.directory] = latest }
            }
            guard self.rootURL == rootURL else { return }
            moduleUpdates = updates
            moduleUpdatesError = failure
            isCheckingModuleUpdates = false
        }
    }

    /// Checks for updates the first time the sidebar is shown for this project.
    func checkModuleUpdatesIfNeeded() {
        guard checkedModuleUpdatesRoot != rootURL else { return }
        checkModuleUpdates()
    }

    func upgrade(_ paths: [String], in group: ModuleGroup) {
        guard !paths.isEmpty else { return }
        runGo(["get"] + paths.map { "\($0)@latest" }, directory: group.directory) { [weak self] status in
            guard let self, status == 0 else { return }
            for path in paths { self.moduleUpdates[group.directory]?[path] = nil }
            self.reloadModules()
        }
    }

    func tidy(_ group: ModuleGroup) {
        runGo(["mod", "tidy"], directory: group.directory) { [weak self] _ in self?.reloadModules() }
    }

    /// `go mod why -m`: which package of the module needs `path`.
    func explainDependency(_ path: String, in group: ModuleGroup) {
        runGo(["mod", "why", "-m", path], directory: group.directory)
    }

    func openRequirement(line: Int, in group: ModuleGroup) {
        navigate(to: group.goModURL, position: TextPosition(line: line, character: 0))
    }

    // MARK: go.work

    /// `go work init` with every module in the project.
    func createGoWork() {
        guard let rootURL else { return }
        let uses = modules.map { GoModuleFinder.relativeUsePath($0.directory, root: rootURL) }
        runGo(["work", "init"] + uses) { [weak self] _ in self?.afterGoWorkChange() }
    }

    func setInWorkspace(_ group: ModuleGroup, _ include: Bool) {
        guard let rootURL else { return }
        let path = GoModuleFinder.relativeUsePath(group.directory, root: rootURL)
        let arguments = include ? ["work", "use", path] : ["work", "edit", "-dropuse=\(path)"]
        runGo(arguments) { [weak self] _ in self?.afterGoWorkChange() }
    }

    func syncGoWork() {
        runGo(["work", "sync"]) { [weak self] _ in self?.reloadModules() }
    }

    private func afterGoWorkChange() {
        reloadModules()
        if let goWorkURL { handleFileSystemChanges([goWorkURL.path]) }  // tell gopls without waiting for FSEvents
        checkedModuleUpdatesRoot = nil
    }
}
