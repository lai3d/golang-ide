import GoIDECore
import SwiftUI

/// Sheet: every line a rename touches, grouped by file, before → after.
struct RenamePreviewView: View {
    @Environment(Workspace.self) private var workspace
    let preview: RenamePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rename ‘\(preview.oldName)’ → ‘\(preview.newName)’").font(.headline)
                Text("\(preview.occurrenceCount) occurrence\(preview.occurrenceCount == 1 ? "" : "s") in \(preview.files.count) file\(preview.files.count == 1 ? "" : "s"). Uncheck files to leave them unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(preview.files) { file in fileSection(file) }
                }
                .padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.renamePreview = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { workspace.applyRenamePreview() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.files.allSatisfy { preview.excluded.contains($0.uri) })
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 360, idealHeight: 520)
    }

    private func fileSection(_ file: RenamePreview.File) -> some View {
        let included = Binding(
            get: { !(workspace.renamePreview?.excluded.contains(file.uri) ?? false) },
            set: { on in
                if on { workspace.renamePreview?.excluded.remove(file.uri) }
                else { workspace.renamePreview?.excluded.insert(file.uri) }
            })
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: included) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                    Text(file.path).font(.callout.weight(.semibold))
                    Text("\(file.edits.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(file.hunks) { hunk in
                    HunkRow(hunk: hunk, oldName: preview.oldName, newName: preview.newName)
                }
            }
            .padding(.leading, 20)
            .opacity(included.wrappedValue ? 1 : 0.4)
        }
    }
}

private struct HunkRow: View {
    let hunk: EditPreviewHunk
    let oldName: String
    let newName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(hunk.line + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(hunk.before, word: oldName, color: .red))
                Text(highlighted(hunk.after, word: newName, color: .green))
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
        }
    }

    /// The code trimmed of indentation, with `word` tinted.
    private func highlighted(_ code: String, word: String, color: Color) -> AttributedString {
        let trimmed = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop { $0 == "\t" || $0 == " " } }.joined(separator: "\n")
        var result = AttributedString(trimmed)
        guard !word.isEmpty else { return result }
        var searchStart = result.startIndex
        while let range = result[searchStart...].range(of: word) {
            result[range].backgroundColor = color.opacity(0.22)
            searchStart = range.upperBound
        }
        return result
    }
}
