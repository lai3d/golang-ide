import GoIDECore
import SwiftUI

/// Find in project: query field, options, and results grouped by file.
struct SearchView: View {
    @Environment(Workspace.self) private var workspace
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var workspace = workspace
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                TextField("Find in project", text: $workspace.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { Task { await workspace.performSearch() } }
                OptionToggle(label: "Aa", help: "Match Case", isOn: $workspace.searchOptions.caseSensitive)
                OptionToggle(label: "ab", help: "Whole Word", isOn: $workspace.searchOptions.wholeWord, underline: true)
                OptionToggle(label: ".*", help: "Regular Expression", isOn: $workspace.searchOptions.regex)
            }
            .padding(.horizontal, 10)

            Group {
                if let error = workspace.searchError {
                    Text(error).foregroundStyle(.red)
                } else if workspace.isSearching {
                    Text("Searching…")
                } else if !workspace.searchQuery.isEmpty {
                    let files = workspace.searchResults.count
                    Text("\(workspace.searchMatchCount) results in \(files) file\(files == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 12)

            List {
                ForEach(workspace.searchResults) { file in
                    Section {
                        ForEach(file.matches) { match in
                            Button { workspace.open(match, in: file) } label: {
                                MatchRow(match: match)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        FileHeader(path: workspace.displayPath(file.path), count: file.matches.count)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .onChange(of: workspace.searchQuery) { workspace.scheduleSearch() }
        .onChange(of: workspace.searchOptions) { workspace.scheduleSearch() }
        .onChange(of: workspace.searchFocusRequest, initial: true) { fieldFocused = true }
    }
}

private struct OptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var underline = false

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .underline(underline)
                .frame(width: 18)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(help)
    }
}

private struct FileHeader: View {
    let path: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text").font(.caption)
            Text((path as NSString).lastPathComponent).fontWeight(.semibold)
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                Text(dir).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .background(.quaternary, in: Capsule())
        }
        .font(.callout)
    }
}

private struct MatchRow: View {
    let match: SearchMatch

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(match.line + 1)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 26, alignment: .trailing)
            Text(highlighted)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
    }

    private var highlighted: AttributedString {
        var text = AttributedString(match.preview)
        if let range = Range(match.previewRange, in: match.preview), let attributed = Range(range, in: text) {
            text[attributed].backgroundColor = .yellow.opacity(0.45)
            text[attributed].foregroundColor = .primary
        }
        return text
    }
}
