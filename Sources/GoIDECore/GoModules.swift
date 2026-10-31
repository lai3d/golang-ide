import Foundation

/// A parsed `go.mod` (the parts the Dependencies sidebar shows). Lines are 0-based.
public struct GoModFile: Sendable, Equatable {
    public struct Requirement: Sendable, Equatable, Identifiable {
        public var path: String
        public var version: String
        public var indirect: Bool
        public var line: Int
        public var id: String { path }
    }

    public struct Replacement: Sendable, Equatable {
        public var oldPath: String
        public var oldVersion: String?
        public var newPath: String
        public var newVersion: String?
        public var line: Int
        /// `=> ../local` (a directory, not a module version).
        public var isLocal: Bool { newVersion == nil }
    }

    public var module: String?
    public var moduleLine = 0
    public var goVersion: String?
    public var toolchain: String?
    public var requires: [Requirement] = []
    public var replaces: [Replacement] = []

    public var direct: [Requirement] { requires.filter { !$0.indirect } }
    public var indirect: [Requirement] { requires.filter(\.indirect) }

    public func replacement(for path: String) -> Replacement? {
        replaces.last { $0.oldPath == path }
    }

    public init() {}

    public static func parse(_ text: String) -> GoModFile {
        var file = GoModFile()
        for directive in GoModLexer.directives(in: text) {
            let args = directive.args
            switch directive.verb {
            case "module":
                file.module = args.first
                file.moduleLine = directive.line
            case "go":
                file.goVersion = args.first
            case "toolchain":
                file.toolchain = args.first
            case "require" where args.count >= 2:
                file.requires.append(Requirement(path: args[0], version: args[1],
                                                 indirect: directive.comment.contains("indirect"), line: directive.line))
            case "replace":
                if let replacement = GoModLexer.replacement(args, line: directive.line) { file.replaces.append(replacement) }
            default:
                break
            }
        }
        return file
    }
}

/// A parsed `go.work`.
public struct GoWorkFile: Sendable, Equatable {
    public struct Use: Sendable, Equatable {
        public var path: String
        public var line: Int
    }

    public var goVersion: String?
    public var uses: [Use] = []
    public var replaces: [GoModFile.Replacement] = []

    public init() {}

    public static func parse(_ text: String) -> GoWorkFile {
        var file = GoWorkFile()
        for directive in GoModLexer.directives(in: text) {
            switch directive.verb {
            case "go": file.goVersion = directive.args.first
            case "use": if let path = directive.args.first { file.uses.append(Use(path: path, line: directive.line)) }
            case "replace":
                if let replacement = GoModLexer.replacement(directive.args, line: directive.line) {
                    file.replaces.append(replacement)
                }
            default: break
            }
        }
        return file
    }

    /// Absolute module directories, relative to the `go.work` directory.
    public func moduleDirectories(relativeTo directory: URL) -> [URL] {
        uses.map { use in
            let url = use.path.hasPrefix("/") ? URL(fileURLWithPath: use.path)
                : directory.appendingPathComponent(use.path)
            return url.standardizedFileURL
        }
    }
}

/// Tokenizes go.mod / go.work: `verb args // comment`, with `verb ( … )` blocks.
enum GoModLexer {
    struct Directive {
        var verb: String
        var args: [String]
        var comment: String
        var line: Int
    }

    static func directives(in text: String) -> [Directive] {
        var result: [Directive] = []
        var block: String?
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var (code, comment) = splitComment(String(raw))
            code = code.trimmingCharacters(in: .whitespaces)
            if code.isEmpty { continue }
            if let verb = block {
                if code == ")" { block = nil; continue }
                result.append(Directive(verb: verb, args: words(code), comment: comment, line: number))
                continue
            }
            var tokens = words(code)
            let verb = tokens.removeFirst()
            if tokens == ["("] {
                block = verb
            } else {
                result.append(Directive(verb: verb, args: tokens, comment: comment, line: number))
            }
        }
        return result
    }

    static func replacement(_ args: [String], line: Int) -> GoModFile.Replacement? {
        guard let arrow = args.firstIndex(of: "=>"), arrow >= 1, args.count > arrow + 1 else { return nil }
        let old = args[..<arrow], new = args[(arrow + 1)...]
        return GoModFile.Replacement(oldPath: old.first!, oldVersion: old.count > 1 ? old[old.startIndex + 1] : nil,
                                     newPath: new.first!, newVersion: new.count > 1 ? new[new.startIndex + 1] : nil,
                                     line: line)
    }

    /// Splits off a `//` comment that isn't inside a quoted string.
    private static func splitComment(_ line: String) -> (String, String) {
        var inQuote: Character?
        var previous: Character?
        for index in line.indices {
            let c = line[index]
            if let q = inQuote {
                if c == q, previous != "\\" || q == "`" { inQuote = nil }
            } else if c == "\"" || c == "`" {
                inQuote = c
            } else if c == "/", previous == "/" {
                let start = line.index(before: index)
                return (String(line[..<start]), String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces))
            }
            previous = c
        }
        return (line, "")
    }

    private static func words(_ code: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for c in code {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "`" {
                quote = c
            } else if c == " " || c == "\t" {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// One module from `go list -m -json [-u] all`.
public struct GoModuleInfo: Sendable, Equatable, Decodable {
    public struct Replacement: Sendable, Equatable, Decodable {
        public var path: String
        public var version: String?
        enum CodingKeys: String, CodingKey { case path = "Path", version = "Version" }
    }

    public var path: String
    public var version: String?
    public var isMain: Bool
    public var indirect: Bool
    public var dir: String?
    public var goMod: String?
    /// The newest available version (`-u`), if newer than `version`.
    public var latestVersion: String?
    public var replace: Replacement?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case path = "Path", version = "Version", main = "Main", indirect = "Indirect", dir = "Dir"
        case goMod = "GoMod", update = "Update", replace = "Replace", error = "Error"
    }

    private struct Nested: Decodable {
        var Version: String?
        var Err: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        isMain = try c.decodeIfPresent(Bool.self, forKey: .main) ?? false
        indirect = try c.decodeIfPresent(Bool.self, forKey: .indirect) ?? false
        dir = try c.decodeIfPresent(String.self, forKey: .dir)
        goMod = try c.decodeIfPresent(String.self, forKey: .goMod)
        latestVersion = try c.decodeIfPresent(Nested.self, forKey: .update)?.Version
        replace = try c.decodeIfPresent(Replacement.self, forKey: .replace)
        error = try c.decodeIfPresent(Nested.self, forKey: .error)?.Err
    }
}

public enum GoModuleList {
    /// Decodes the stream of concatenated JSON objects `go list -json` prints.
    public static func parse(_ data: Data) -> [GoModuleInfo] {
        let decoder = JSONDecoder()
        return objects(in: data).compactMap { try? decoder.decode(GoModuleInfo.self, from: $0) }
    }

    /// Splits `{…}{…}` at top-level brace boundaries (ignoring braces inside strings).
    static func objects(in data: Data) -> [Data] {
        var result: [Data] = []
        var depth = 0, start = 0
        var inString = false, escaped = false
        let bytes = [UInt8](data)
        for (i, b) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x22: inString = true
            case 0x7B:
                if depth == 0 { start = i }
                depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0 { result.append(Data(bytes[start...i])) }
            default: break
            }
        }
        return result
    }
}

public enum GoModuleFinder {
    /// `go.mod` files in the project (skipping vendor/, testdata/ and ignored directories), root first.
    public static func goModFiles(under root: URL) -> [URL] {
        let rootPath = root.canonicalFileURL.path
        return ProjectSearch.files(under: root)
            .filter { $0.hasSuffix("/go.mod") && !$0.contains("/vendor/") && !$0.contains("/testdata/") }
            .sorted { lhs, rhs in
                let l = lhs == rootPath + "/go.mod", r = rhs == rootPath + "/go.mod"
                return l != r ? l : lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The `go work use` argument for `directory` relative to the workspace root (`./sub`, or `.`).
    public static func relativeUsePath(_ directory: URL, root: URL) -> String {
        let dir = directory.canonicalFileURL.path, rootPath = root.canonicalFileURL.path
        if dir == rootPath { return "." }
        if dir.hasPrefix(rootPath + "/") { return "./" + dir.dropFirst(rootPath.count + 1) }
        return dir
    }
}

/// Runs a `go` subcommand to completion (blocking; call off the main thread).
public enum GoCommand {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        public var errorOutput: String
    }

    public static func run(_ arguments: [String], in directory: URL) -> Result {
        guard let go = ToolLocator.find("go") else {
            return Result(status: -1, output: Data(), errorOutput: "go not found")
        }
        let process = Process()
        process.executableURL = go
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ToolLocator.environment()
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: Data(), errorOutput: error.localizedDescription)
        }
        // Drain stderr concurrently so a chatty command can't fill its pipe and stall.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: data,
                      errorOutput: String(decoding: errData, as: UTF8.self))
    }
}
