import Foundation

/// One row of `go tool pprof -top` (functions) or `-top -lines` (source lines).
public struct ProfileRow: Sendable, Equatable, Identifiable {
    public var flat: String
    public var flatPercent: Double
    public var cum: String
    public var cumPercent: Double
    /// Qualified function name, e.g. `example.com/prof.Fib` or `strings.(*Builder).copyCheck`.
    public var function: String
    public var file: String?
    /// 1-based, as pprof prints it.
    public var line: Int?
    public var isInline: Bool

    public var id: String { "\(function)|\(file ?? "")|\(line ?? 0)" }

    /// `Fib` / `(*Builder).copyCheck`: the name without its package path.
    public var shortName: String {
        let afterSlash = function.split(separator: "/").last.map(String.init) ?? function
        guard let dot = afterSlash.firstIndex(of: ".") else { return afterSlash }
        return String(afterSlash[afterSlash.index(after: dot)...])
    }

    /// `example.com/prof` / `strings`.
    public var package: String {
        let slash = function.lastIndex(of: "/")
        let tail = slash.map { function[function.index(after: $0)...] } ?? function[...]
        guard let dot = tail.firstIndex(of: ".") else { return function }
        return String(function[..<dot])
    }

    public init(flat: String, flatPercent: Double, cum: String, cumPercent: Double, function: String,
                file: String? = nil, line: Int? = nil, isInline: Bool = false) {
        self.flat = flat
        self.flatPercent = flatPercent
        self.cum = cum
        self.cumPercent = cumPercent
        self.function = function
        self.file = file
        self.line = line
        self.isInline = isInline
    }
}

public struct ProfileReport: Sendable, Equatable {
    /// `cpu`, `alloc_space`, `inuse_space`, …
    public var type: String = ""
    /// e.g. `2030ms` or `587.74MB`.
    public var total: String = ""
    /// The "Duration: …" / "Showing nodes …" lines, for display.
    public var summary: [String] = []
    public var rows: [ProfileRow] = []

    public init() {}
}

public enum Pprof {
    /// Parses `go tool pprof -top [-lines]` output.
    public static func parseTop(_ text: String) -> ProfileReport {
        var report = ProfileReport()
        var inTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if !inTable {
                if line.hasPrefix("Type: ") {
                    report.type = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("flat") {
                    inTable = true
                } else if !line.hasPrefix("File: "), !line.hasPrefix("Build ID: "), !line.hasPrefix("Time: ") {
                    report.summary.append(line)
                    if let range = line.range(of: #"of (\S+) total"#, options: .regularExpression) {
                        report.total = String(line[range].dropFirst(3).dropLast(6))
                    }
                }
                continue
            }
            if let row = parseRow(line) { report.rows.append(row) }
        }
        return report
    }

    static func parseRow(_ line: String) -> ProfileRow? {
        // flat flat% sum% cum cum% name… — five whitespace-separated columns, then the rest.
        var rest = Substring(line)
        var columns: [String] = []
        for _ in 0..<5 {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            columns.append(String(rest[..<end]))
            rest = rest[end...]
        }
        var name = rest.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let flatPercent = percent(columns[1]), let cumPercent = percent(columns[4]) else { return nil }
        var isInline = false
        if name.hasSuffix(" (inline)") {
            isInline = true
            name = String(name.dropLast(9))
        }
        var file: String?
        var lineNumber: Int?
        // `-lines`: "pkg.Func /abs/path/file.go:12"
        if let match = name.range(of: #" (/.+):(\d+)$"#, options: .regularExpression) {
            let location = name[match].dropFirst()
            if let colon = location.lastIndex(of: ":") {
                file = String(location[..<colon])
                lineNumber = Int(location[location.index(after: colon)...])
            }
            name = String(name[..<match.lowerBound])
        }
        return ProfileRow(flat: columns[0], flatPercent: flatPercent, cum: columns[3], cumPercent: cumPercent,
                          function: name, file: file, line: lineNumber, isInline: isInline)
    }

    private static func percent(_ s: String) -> Double? {
        Double(s.hasSuffix("%") ? String(s.dropLast()) : s)
    }

    /// Gives function rows a location: the earliest sampled line of that function (from a `-lines` report).
    public static func locate(_ functions: [ProfileRow], using lines: [ProfileRow]) -> [ProfileRow] {
        var first: [String: (file: String, line: Int)] = [:]
        for row in lines {
            guard let file = row.file, let line = row.line else { continue }
            if let existing = first[row.function], existing.file == file, existing.line <= line { continue }
            first[row.function] = (file, line)
        }
        return functions.map { row in
            var row = row
            if row.file == nil, let location = first[row.function] {
                row.file = location.file
                row.line = location.line
            }
            return row
        }
    }
}
