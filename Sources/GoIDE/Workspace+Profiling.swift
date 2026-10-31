import AppKit
import GoIDECore

enum ProfileKind: String {
    case cpu = "CPU"
    case memory = "Memory"
}

/// A captured pprof profile of one package's benchmarks or tests.
struct ProfileSession {
    let kind: ProfileKind
    let benchmarks: Bool
    let title: String
    let directory: URL
    /// Holds the test binary and the .pprof file (removed when replaced or on close).
    let scratch: URL
    var report = ProfileReport()
    var lines: [ProfileRow] = []
    var isLoading = true
    var error: String?

    var binary: URL { scratch.appendingPathComponent("pkg.test") }
    var profileFile: URL { scratch.appendingPathComponent(kind == .cpu ? "cpu.pprof" : "mem.pprof") }
    var sampleIndex: [String] { kind == .memory ? ["-sample_index=alloc_space"] : [] }
}

extension Workspace {
    /// Profiles the active file's package (or the project root) with `go test -cpuprofile / -memprofile`.
    func profilePackage(_ kind: ProfileKind, benchmarks: Bool) {
        guard let rootURL, !isRunning else { return }
        let directory = activeDocument.map { $0.url.deletingLastPathComponent() } ?? rootURL
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("goide-profile-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        discardProfile()
        let relative = directory.canonicalFileURL == rootURL.canonicalFileURL
            ? rootURL.lastPathComponent : GoModuleFinder.relativeUsePath(directory, root: rootURL)
        var session = ProfileSession(kind: kind, benchmarks: benchmarks,
                                     title: "\(relative) \(benchmarks ? "benchmarks" : "tests")",
                                     directory: directory, scratch: scratch)
        profile = session
        var arguments = ["test"]
        arguments += benchmarks ? ["-run", "^$", "-bench", ".", "-benchmem"] : ["-count=1"]
        arguments += [kind == .cpu ? "-cpuprofile" : "-memprofile", session.profileFile.path,
                      "-o", session.binary.path, "."]
        runGo(arguments, directory: directory) { [weak self] status in
            guard let self, self.profile?.scratch == scratch else { return }
            guard status == 0, FileManager.default.fileExists(atPath: session.profileFile.path) else {
                session.isLoading = false
                session.error = "go test failed — see Output."
                self.profile = session
                return
            }
            let base = ["tool", "pprof", "-top", "-nodecount=500"] + session.sampleIndex
            let files = [session.binary.path, session.profileFile.path]
            Task {
                let (functions, lines) = await Task.detached {
                    let functions = GoCommand.run(base + files, in: directory)
                    let lines = GoCommand.run(base + ["-lines"] + files, in: directory)
                    return (Pprof.parseTop(String(decoding: functions.output, as: UTF8.self)),
                            Pprof.parseTop(String(decoding: lines.output, as: UTF8.self)))
                }.value
                guard self.profile?.scratch == scratch else { return }
                session.report = functions
                session.report.rows = Pprof.locate(functions.rows, using: lines.rows)
                session.lines = lines.rows
                session.isLoading = false
                if functions.rows.isEmpty {
                    session.error = benchmarks
                        ? "No samples. Does this package have benchmarks (func BenchmarkXxx)?"
                        : "No samples. The tests may run too briefly to profile; try benchmarks."
                }
                self.profile = session
                self.bottomTab = .profile
            }
        }
    }

    /// Opens the interactive pprof web UI (flame graph, graph, source) in the browser.
    func openProfileInBrowser() {
        guard let session = profile, !session.isLoading, session.error == nil,
              let go = ToolLocator.find("go") else { return }
        pprofWebProcess?.terminate()
        let process = Process()
        process.executableURL = go
        process.arguments = ["tool", "pprof", "-http=localhost:0"] + session.sampleIndex
            + [session.binary.path, session.profileFile.path]
        process.currentDirectoryURL = session.directory
        process.environment = ToolLocator.environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            pprofWebProcess = process
            flashStatus("Opening pprof in the browser…")
        } catch {
            flashStatus("Couldn't start pprof: \(error.localizedDescription)")
        }
    }

    /// Stops the web UI and deletes the profile's scratch files.
    func discardProfile() {
        pprofWebProcess?.terminate()
        pprofWebProcess = nil
        if let scratch = profile?.scratch { try? FileManager.default.removeItem(at: scratch) }
        profile = nil
    }

    func reveal(_ row: ProfileRow) {
        guard let file = row.file, let line = row.line, FileManager.default.fileExists(atPath: file) else {
            flashStatus("No source location for \(row.shortName)")
            return
        }
        navigate(to: URL(fileURLWithPath: file), position: TextPosition(line: max(0, line - 1), character: 0))
    }
}
