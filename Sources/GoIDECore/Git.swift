import Foundation

public enum GitFileStatus: String, Sendable, Hashable {
    case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "?", conflicted = "U"
}

/// Small synchronous wrappers around the `git` CLI (call off the main thread).
public enum Git {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    @discardableResult
    public static func run(_ arguments: [String], in directory: URL) -> Result {
        guard let git = ToolLocator.find("git") else { return Result(status: -1, output: "") }
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ToolLocator.environment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// The repository's top-level directory, or nil if `directory` isn't in a Git work tree.
    public static func topLevel(of directory: URL) -> URL? {
        let result = run(["rev-parse", "--show-toplevel"], in: directory)
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !path.isEmpty ? URL(fileURLWithPath: path).canonicalFileURL : nil
    }

    public static func currentBranch(in directory: URL) -> String? {
        let branch = run(["branch", "--show-current"], in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { return branch }
        let head = run(["rev-parse", "--short", "HEAD"], in: directory)  // detached HEAD
        return head.status == 0 ? "(" + head.output.trimmingCharacters(in: .whitespacesAndNewlines) + ")" : nil
    }

    /// Statuses keyed by absolute path, from `git status --porcelain=v1 -z`.
    public static func status(in topLevel: URL) -> [String: GitFileStatus] {
        // --no-optional-locks: don't rewrite .git/index (which would retrigger our file watcher).
        let result = run(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"], in: topLevel)
        guard result.status == 0 else { return [:] }
        return parseStatus(result.output, root: topLevel.path)
    }

    public static func parseStatus(_ porcelain: String, root: String) -> [String: GitFileStatus] {
        var statuses: [String: GitFileStatus] = [:]
        var entries = porcelain.split(separator: "\0", omittingEmptySubsequences: true)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let x = entry[entry.startIndex], y = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            let status: GitFileStatus
            switch (x, y) {
            case ("?", "?"): status = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): status = .conflicted
            case ("R", _), ("C", _):
                status = .renamed
                _ = entries.popFirst()  // -z puts the original path in the next field
            case ("A", _): status = .added
            case ("D", _), (_, "D"): status = .deleted
            default: status = .modified
            }
            statuses[(root as NSString).appendingPathComponent(path)] = status
        }
        return statuses
    }

    /// A file's contents at HEAD (nil if it isn't tracked there).
    public static func headContents(of file: URL, topLevel: URL) -> String? {
        let relative = String(file.canonicalFileURL.path.dropFirst(topLevel.path.count + 1))
        let result = run(["show", "HEAD:" + relative], in: topLevel)
        return result.status == 0 ? result.output : nil
    }
}

/// Line-level changes of the current text against a base (e.g. HEAD), for gutter bars.
public struct LineChanges: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case added, modified }

    /// Zero-based lines in the current text.
    public var lines: [Int: Kind] = [:]
    /// Lines in the current text *before which* base lines were deleted.
    public var deletions: Set<Int> = []

    public init(lines: [Int: Kind] = [:], deletions: Set<Int> = []) {
        self.lines = lines
        self.deletions = deletions
    }

    public var isEmpty: Bool { lines.isEmpty && deletions.isEmpty }

    public static func compute(base: String, current: String) -> LineChanges {
        let old = base.components(separatedBy: "\n"), new = current.components(separatedBy: "\n")
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var changes = LineChanges()
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                // A hunk: consecutive removals/insertions. Paired lines are "modified".
                var removedCount = 0
                var added: [Int] = []
                var progressed = true
                while progressed {
                    progressed = false
                    while i < old.count, removed.contains(i) { removedCount += 1; i += 1; progressed = true }
                    while j < new.count, inserted.contains(j) { added.append(j); j += 1; progressed = true }
                }
                if added.isEmpty {
                    changes.deletions.insert(j)
                } else {
                    for (k, line) in added.enumerated() { changes.lines[line] = k < removedCount ? .modified : .added }
                }
            } else {
                i += 1
                j += 1
            }
        }
        return changes
    }
}
