import Foundation

/// gopls settings GoIDE relies on (sent as initializationOptions and workspace/configuration).
public enum GoplsSettings {
    /// Settings with the user's options from `UserDefaults.standard`.
    public static var `default`: JSONValue { GoplsOptions.load().json }
}

/// User-facing gopls options (Settings ▸ Go), stored in UserDefaults.
public struct GoplsOptions: Sendable, Equatable {
    public static let gofumptKey = "gopls.gofumpt"
    public static let localKey = "gopls.local"
    public static let staticcheckKey = "gopls.staticcheck"
    public static let shadowKey = "gopls.analyses.shadow"
    public static let buildTagsKey = "gopls.buildTags"

    /// Stricter gofumpt formatting.
    public var gofumpt = false
    /// Comma-separated import path prefixes grouped after third-party imports (`goimports -local`).
    public var local = ""
    /// Extra staticcheck analyzers.
    public var staticcheck = false
    /// Report shadowed variables.
    public var shadow = false
    /// Comma- or space-separated build tags (`-tags=…`).
    public var buildTags = ""

    public init() {}

    public static func load(from defaults: UserDefaults = .standard) -> GoplsOptions {
        var options = GoplsOptions()
        options.gofumpt = defaults.bool(forKey: gofumptKey)
        options.local = defaults.string(forKey: localKey) ?? ""
        options.staticcheck = defaults.bool(forKey: staticcheckKey)
        options.shadow = defaults.bool(forKey: shadowKey)
        options.buildTags = defaults.string(forKey: buildTagsKey) ?? ""
        return options
    }

    /// Normalized `-tags=a,b`, or nil when no tags are set.
    public var buildFlag: String? {
        let tags = buildTags.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        return tags.isEmpty ? nil : "-tags=" + tags.joined(separator: ",")
    }

    public var json: JSONValue {
        var settings: [String: JSONValue] = [
            "hints": [
                "assignVariableTypes": true, "compositeLiteralFields": true, "constantValues": true,
                "functionTypeParameters": true, "parameterNames": true, "rangeVariableTypes": true,
            ],
            "semanticTokens": true,
            "usePlaceholders": true,  // function call completions get parameter placeholders
            "gofumpt": .bool(gofumpt),
            "staticcheck": .bool(staticcheck),
            "analyses": ["shadow": .bool(shadow)],
        ]
        let local = self.local.trimmingCharacters(in: .whitespaces)
        if !local.isEmpty { settings["local"] = .string(local) }
        if let buildFlag { settings["buildFlags"] = [.string(buildFlag)] }
        return .object(settings)
    }
}

/// One decoded semantic token (`textDocument/semanticTokens/full`).
public struct SemanticToken: Sendable, Hashable {
    public let line: Int
    /// UTF-16 start column and length.
    public let start: Int
    public let length: Int
    public let type: String
    public let modifiers: Set<String>

    public init(line: Int, start: Int, length: Int, type: String, modifiers: Set<String> = []) {
        self.line = line
        self.start = start
        self.length = length
        self.type = type
        self.modifiers = modifiers
    }
}

/// The server's token legend, from `capabilities.semanticTokensProvider.legend`.
public struct SemanticTokenLegend: Sendable, Hashable {
    public let types: [String]
    public let modifiers: [String]

    public init(types: [String], modifiers: [String]) {
        self.types = types
        self.modifiers = modifiers
    }

    public init?(initializeResult: JSONValue) {
        let legend = initializeResult["capabilities"]?["semanticTokensProvider"]?["legend"]
        guard let types = legend?["tokenTypes"]?.arrayValue?.compactMap(\.stringValue) else { return nil }
        self.init(types: types, modifiers: legend?["tokenModifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// Decodes the relative 5-integer encoding: Δline, Δstart, length, type, modifier bits.
    public func decode(_ result: JSONValue) -> [SemanticToken] {
        let data = result["data"]?.arrayValue?.compactMap(\.intValue) ?? []
        var tokens: [SemanticToken] = []
        tokens.reserveCapacity(data.count / 5)
        var line = 0, start = 0
        var i = 0
        while i + 4 < data.count {
            let deltaLine = data[i], deltaStart = data[i + 1]
            line += deltaLine
            start = deltaLine == 0 ? start + deltaStart : deltaStart
            let typeIndex = data[i + 3], bits = data[i + 4]
            if types.indices.contains(typeIndex) {
                var mods = Set<String>()
                for (bit, name) in modifiers.enumerated() where bits & (1 << bit) != 0 { mods.insert(name) }
                tokens.append(SemanticToken(line: line, start: start, length: data[i + 2], type: types[typeIndex], modifiers: mods))
            }
            i += 5
        }
        return tokens
    }

    /// Token types/modifiers GoIDE asks for in its client capabilities.
    public static let clientTypes: [String] = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable",
        "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment",
        "string", "number", "regexp", "operator", "decorator", "label",
    ]
    public static let clientModifiers: [String] = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async",
        "modification", "documentation", "defaultLibrary",
    ]
}
